# Source all environment variables
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo ".env file not found"
    exit 1
fi

# upload the test pyspark scripts to the GCS bucket
gcloud storage cp spark_files/$TEST_FILE gs://$BUCKET_NAME/

# Submit a PySpark jobs to the Dataproc cluster
gcloud dataproc jobs submit pyspark gs://$BUCKET_NAME/$TEST_FILE \
      --cluster=secure-dataproc-cluster \
      --region=us-central1 \
      --async \
      -- $BUCKET_NAME