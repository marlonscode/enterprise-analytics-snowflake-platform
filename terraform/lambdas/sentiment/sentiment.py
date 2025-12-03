import boto3
import json
import os
import requests
from datetime import datetime, timedelta

ALPHA_VANTAGE_API_KEY = os.environ.get("ALPHA_VANTAGE_API_KEY")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
S3_BUCKET_NAME = os.environ.get("S3_BUCKET_NAME")

sns_client = boto3.client("sns")
s3_client = boto3.client("s3")

def handler(event, context):
    print("Received scheduled event:", event)

    # Construct Alpha Vantage API URL for Sentiment data
    now = datetime.utcnow()
    time_to = now.strftime("%Y%m%dT%H%M")
    time_from = (now - timedelta(days=1)).strftime("%Y%m%dT%H%M")
    url = f'https://www.alphavantage.co/query?function=NEWS_SENTIMENT&tickers=AAPL&time_from={time_from}&time_to={time_to}&apikey={ALPHA_VANTAGE_API_KEY}'

    try:
        # 1. Fetch Sentiment data
        response = requests.get(url)
        response.raise_for_status()
        sentiment_data = response.json()
        message = {
            "status": "processed",
            "message": "Sentiment data pulled successfully",
            "data": sentiment_data
        }

        # 2. Publish to SNS
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Message=json.dumps(message.get("message", {}))
        )

        # 3. Push to S3
        feed_items = sentiment_data.get("feed", [])
        jsonl_body = "\n".join(json.dumps(item) for item in feed_items)
        timestamp = datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%SZ")
        s3_key = f"sentiment/sentiment_{timestamp}.jsonl"
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=jsonl_body,
            ContentType="application/json"
        )
        print(f"Data successfully written to s3://{S3_BUCKET_NAME}/{s3_key}")

        return {
            "statusCode": 200,
            "body": json.dumps({"message": "Sentiment data pushed to SNS and S3"})
        }

    except requests.exceptions.HTTPError as e:
        print(f"HTTP error fetching Alpha Vantage data: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Failed to fetch sentiment data"})
        }

    except Exception as e:
        print(f"Unexpected error: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "An unexpected error occurred"})
        }
