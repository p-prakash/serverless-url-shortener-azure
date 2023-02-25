''' Azure Function to shorten the URL'''

import os
import re
import json
import logging
import string
import secrets
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient, exceptions

app = func.FunctionApp()
DB_ENDPOINT = os.environ['DATABASE_URL'].rstrip('/')
DB_NAME = os.environ['DATABASE_NAME']
DB_CONTAINER = os.environ['DATABASE_CONTAINER']
SHORT_URL = os.environ['SHORT_URL'].rstrip('/')
db_credential = DefaultAzureCredential()
# db_credential = ''

try:
    cosmos_client = CosmosClient(url=DB_ENDPOINT, credential=db_credential)
    db_client = cosmos_client.get_database_client(DB_NAME)
    db_container = db_client.get_container_client(DB_CONTAINER)
except exceptions.CosmosResourceNotFoundError:
    logging.error('CosmosDB database or container does not exist')


def generate_url_hash():
    'Generate random 8 digit alphanumeric hash'
    return ''.join(secrets.choice(string.ascii_letters + string.digits) for i in range(8))


def main(req: func.HttpRequest) -> func.HttpResponse:
    'Function to list the URLs'
    logging.info('Python HTTP trigger function processed list urls request.')
    logging.info(req.get_json())
    oid = req.get_json().get('oid')

    try:
        url_list = []
        db_items = db_container.query_items(
            query=f"SELECT c.id, c.target_url FROM c WHERE (c.oid = '{oid}')",
            enable_cross_partition_query=True
        )
        for item in db_items:
            try:
                url = item['target_url']
                url_req = Request(url, method='HEAD')
                url_res = urlopen(url_req)
                url_status = url_res.status
            except HTTPError as err:
                url_status = err.status
            url_list.append({'target_url': url, 'id': item['id'], 'status': url_status})

        return func.HttpResponse(
            json.dumps(url_list),
            mimetype='application/json',
            charset='utf-8',
            status_code=200
        )
    except (exceptions.CosmosResourceNotFoundError,
        exceptions.CosmosClientTimeoutError,
        exceptions.CosmosHttpResponseError) as err:
        logging.error(err)
        return func.HttpResponse(
            json.dumps({"message": "Failed to obtain the list of URLs."}),
            mimetype='application/json',
            charset='utf-8',
            status_code=500
        )        
