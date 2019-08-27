#!/usr/bin/env bash
#
# Starts three Prometheus servers scraping themselves and sidecars for each.
# Two query nodes are started and all are clustered together.

trap 'kill 0' SIGTERM

MINIO_EXECUTABLE="minio"
MC_EXECUTABLE="mc"
PROMETHEUS_EXECUTABLE="./prometheus"
THANOS_EXECUTABLE="./thanos"

# Start local object storage, if desired.
# NOTE: If you would like to use an actual S3-compatible API with this setup
#       set the S3_* environment variables set in the Minio example.
if [ -n "${MINIO_ENABLED}" ]
then
  export MINIO_ACCESS_KEY="THANOS"
  export MINIO_SECRET_KEY="ITSTHANOSTIME"
  export MINIO_ENDPOINT="127.0.0.1:9000"
  export MINIO_BUCKET="thanos"
  export S3_ACCESS_KEY=${MINIO_ACCESS_KEY}
  export S3_SECRET_KEY=${MINIO_SECRET_KEY}
  export S3_BUCKET=${MINIO_BUCKET}
  export S3_ENDPOINT=${MINIO_ENDPOINT}
  export S3_INSECURE="true"
  export S3_V2_SIGNATURE="true"
  rm -rf data/minio
  mkdir -p data/minio

  ${MINIO_EXECUTABLE} server ./data/minio \
      --address ${MINIO_ENDPOINT} &
  sleep 3
  # create the bucket
  ${MC_EXECUTABLE} config host add tmp http://${MINIO_ENDPOINT} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
  ${MC_EXECUTABLE} mb tmp/${MINIO_BUCKET}
  ${MC_EXECUTABLE} config host rm tmp

  cat <<EOF > data/bucket.yml
type: S3
config:
  bucket: $S3_BUCKET
  endpoint: $S3_ENDPOINT
  insecure: $S3_INSECURE
  signature_version2: $S3_V2_SIGNATURE
  access_key: $S3_ACCESS_KEY
  secret_key: $S3_SECRET_KEY
EOF
fi

STORES=""

# Start three Prometheus servers monitoring themselves.
for i in `seq 1 3`
do
  rm -rf data/prom${i}
  mkdir -p data/prom${i}/

  cat > data/prom${i}/prometheus.yml <<- EOF
global:
  external_labels:
    prometheus: prom-${i}
scrape_configs:
- job_name: prometheus
  scrape_interval: 5s
  static_configs:
  - targets:
    - "localhost:909${i}"
- job_name: thanos-sidecar
  scrape_interval: 5s
  static_configs:
  - targets:
    - "localhost:1919${i}"
- job_name: thanos-store
  scrape_interval: 5s
  static_configs:
  - targets:
    - "localhost:19791"
- job_name: thanos-query
  scrape_interval: 5s
  static_configs:
  - targets:
    - "localhost:19491"
    - "localhost:19492"
EOF

  ${PROMETHEUS_EXECUTABLE} \
    --config.file         data/prom${i}/prometheus.yml \
    --storage.tsdb.path   data/prom${i} \
    --log.level           warn \
    --web.enable-lifecycle \
    --storage.tsdb.min-block-duration=2h \
    --storage.tsdb.max-block-duration=2h \
    --web.listen-address  0.0.0.0:909${i} &

  sleep 0.25
done

sleep 0.5

OBJSTORECFG=""
if [ -n "${MINIO_ENABLED}" ]
then
OBJSTORECFG="--objstore.config-file      data/bucket.yml"
fi

# Start one sidecar for each Prometheus server.
for i in `seq 1 3`
do
  ${THANOS_EXECUTABLE} sidecar \
    --debug.name                sidecar-${i} \
    --grpc-address              0.0.0.0:1909${i} \
    --http-address              0.0.0.0:1919${i} \
    --prometheus.url            http://localhost:909${i} \
    --tsdb.path                 data/prom${i} \
    ${OBJSTORECFG} &

  STORES="${STORES} --store 127.0.0.1:1909${i}"

  sleep 0.25
done

sleep 0.5

if [ -n "${GCS_BUCKET}" -o -n "${S3_ENDPOINT}" ]
then
  ${THANOS_EXECUTABLE} store \
    --debug.name                store \
    --log.level                 debug \
    --grpc-address              0.0.0.0:19691 \
    --http-address              0.0.0.0:19791 \
    --data-dir                  data/store \
    ${OBJSTORECFG} &

  STORES="${STORES} --store 127.0.0.1:19691"
fi

sleep 0.5

if [ -n "${REMOTE_WRITE_ENABLED}" ]
then
  ${THANOS_EXECUTABLE} receive \
    --debug.name                receive \
    --log.level                 debug \
    --tsdb.path                 "./data/remote-write-receive-data" \
    --grpc-address              0.0.0.0:19891 \
    --http-address              0.0.0.0:18091 \
    --labels                    "receive=\"true\"" \
    ${OBJSTORECFG} \
    --remote-write.address      0.0.0.0:19291 &

  mkdir -p "data/local-prometheus-data/"
  cat <<EOF > data/local-prometheus-data/prometheus.yml
# When the Thanos remote-write-receive component is started,
# this is an example configuration of a Prometheus server that
# would scrape a local node-exporter and replicate its data to
# the remote write endpoint.
scrape_configs:
  - job_name: node
    scrape_interval: 1s
    static_configs:
    - targets: ['localhost:9100']
remote_write:
- url: http://localhost:19291/api/v1/receive
EOF
  ${PROMETHEUS_EXECUTABLE} \
    --config.file data/local-prometheus-data/prometheus.yml \
    --storage.tsdb.path "data/local-prometheus-data/" &

  STORES="${STORES} --store 127.0.0.1:19891"
fi

sleep 0.5

# Start to query nodes.
for i in `seq 1 2`
do
  ${THANOS_EXECUTABLE} query \
    --debug.name                query-${i} \
    --grpc-address              0.0.0.0:1999${i} \
    --http-address              0.0.0.0:1949${i} \
    --query.replica-label       prometheus \
    ${STORES} &
done

wait

