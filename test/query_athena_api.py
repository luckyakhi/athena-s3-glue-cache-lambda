#!/usr/bin/env python3
"""
Send SQL to the Athena proxy API Gateway endpoint and print results.
Equivalent to:
  curl -s -X POST "$API/query" \
       -H "content-type: application/json" \
       -d '{"sql":"SELECT * FROM demoaks_demo_db.demo_table LIMIT 5"}' | jq
"""

import argparse
import json
import requests


def run_query(api_endpoint: str, sql: str):
    url = f"{api_endpoint.rstrip('/')}/query"
    headers = {"content-type": "application/json"}
    payload = {"sql": sql}

    resp = requests.post(url, headers=headers, json=payload)
    resp.raise_for_status()

    data = resp.json()
    return data


def main(api,sql):

    result = run_query(api,sql)

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    api = 'https://8opo51ogmd.execute-api.ap-south-1.amazonaws.com'
    sql= 'SELECT * FROM demoaks_demo_db.demo_table LIMIT 5'
    main(api=api,sql=sql)
