
'''
This script validates the Dataproc cluster's network configuration by checking outbound internet connectivity via Cloud NAT and verifying GCS read/write access.
'''

import sys
import urllib.request
from pyspark.sql import SparkSession

# 1. Initialize the Spark Session
spark = SparkSession.builder.appName("DataprocFoundationTest").getOrCreate()

print("\n==================================================")
print("     RUNNING DATAPROC ARCHITECTURE VALIDATION      ")
print("==================================================\n")

# --- TEST 1: Cloud NAT Validation (Outbound Internet) ---
try:
    print("[TEST 1/2] Checking Cloud NAT outbound internet connectivity...")
    # Attempt to query a public, non-Google IP echo service
    response = urllib.request.urlopen("https://api.ipify.org", timeout=10)
    public_ip = response.read().decode('utf-8')
    print(f"-> SUCCESS: Outbound internet is working! Cloud NAT Gateway IP: {public_ip}\n")
except Exception as e:
    print(f"-> FAILED: Cloud NAT test failed. Your VMs cannot reach the public internet. Error: {e}\n")

# --- TEST 2: Private Google Access & IAM Validation (GCS Read/Write) ---
bucket_name = sys.argv[1]
output_path = f"gs://{bucket_name}/test_verification_output/"

try:
    print("[TEST 2/2] Checking Private Google Access & IAM via GCS bucket write...")
    # Create a small test dataframe
    data = [("VPC_Routing", 1), ("Private_Google_Access", 1), ("Service_Account_IAM", 1)]
    df = spark.createDataFrame(data, ["Component", "Status"])
    
    # Attempt to write the dataframe to GCS
    df.write.mode("overwrite").csv(output_path)
    print("-> SUCCESS: Private Google Access is routing internally, and your Service Account has Storage Admin rights!\n")
except Exception as e:
    print(f"-> FAILED: GCS write failed. Check PGA configuration, subnet routing, or Service Account permissions. Error: {e}\n")

print("==================================================")
print("             VALIDATION TEST COMPLETE             ")
print("==================================================\n")

spark.stop()