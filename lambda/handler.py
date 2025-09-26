import os, json, time, hashlib
import boto3
import redis

REGION    = os.environ.get("AWS_REGION")
WG        = os.environ.get("ATHENA_WG")
DB        = os.environ.get("GLUE_DB")
S3_OUTPUT = os.environ.get("S3_OUTPUT")
REDIS_HOST= os.environ.get("REDIS_HOST")
REDIS_PORT= int(os.environ.get("REDIS_PORT","6379"))
TTL       = int(os.environ.get("CACHE_TTL","300"))

athena = boto3.client("athena", region_name=REGION)
r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, ssl=True, socket_timeout=2)

def run_sql(sql: str):
    key = "athena:" + hashlib.sha256(sql.encode()).hexdigest()[:32]
    hit = r.get(key)
    if hit:
        return json.loads(hit), True
    q = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": DB},
        WorkGroup=WG,
        ResultConfiguration={"OutputLocation": S3_OUTPUT}
    )
    qid = q["QueryExecutionId"]
    for _ in range(60):
        st = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]["State"]
        if st in ("SUCCEEDED","FAILED","CANCELLED"):
            break
        time.sleep(1)
    if st != "SUCCEEDED":
        return {"error": f"Query {qid} ended in {st}"}, False
    rows = athena.get_query_results(QueryExecutionId=qid, MaxResults=200)
    hdr = [c["VarCharValue"] for c in rows["ResultSet"]["Rows"][0]["Data"]]
    out=[]
    for row in rows["ResultSet"]["Rows"][1:101]:
        vals=[d.get("VarCharValue") for d in row["Data"]]
        out.append(dict(zip(hdr, vals)))
    payload = {"query_id": qid, "rows": out}
    r.setex(key, TTL, json.dumps(payload))
    return payload, False

def handler(event, context):
    try:
        body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            import base64
            body = base64.b64decode(body).decode()
        data = json.loads(body)
        sql = data.get("sql") or "SELECT 1"
        result, cached = run_sql(sql)
        return { "statusCode": 200, "headers": {"content-type":"application/json"},
                 "body": json.dumps({"cached": cached, "result": result}) }
    except Exception as e:
        return { "statusCode": 500, "headers": {"content-type":"application/json"},
                 "body": json.dumps({"error": str(e)}) }
