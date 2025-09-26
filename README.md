# Lambda + Private VPC Endpoints — Serverless Athena Cache POC

API Gateway → Lambda (in VPC) → Redis (ElastiCache Serverless) → Athena/S3 via VPC Endpoints.

## Deploy
```bash
cd terraform
terraform init
terraform apply -auto-approve
```

## Upload sample Parquet
```bash
# Produce/obtain a Parquet with columns: id:int, name:string, value:double
aws s3 cp ./sample.parquet s3://$(terraform -chdir=terraform output -raw data_bucket)/parquet/
```

## Query
```bash
API=$(terraform -chdir=terraform output -raw api_endpoint)
curl -s -X POST "$API/query" -H "content-type: application/json"   -d '{"sql":"SELECT * FROM demoaks_demo_db.demo_table LIMIT 5"}' | jq .
# repeat to see cached:true
```

## Destroy
```bash
cd terraform
terraform destroy -auto-approve
```

### Notes
- No NAT or Internet Gateway; Lambda talks to AWS services via VPC endpoints.
- Interface endpoints cost a little per hour — keep to one AZ and destroy when done.
- Redis connection uses TLS (ssl=True).
