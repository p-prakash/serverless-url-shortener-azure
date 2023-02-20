''' Azure Function to shorten the URL'''

import os
import re
import json
import logging
import string
import secrets
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient
from azure.cosmos import exceptions

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
    'Function to shorten the URL'
    logging.info('Python HTTP trigger function processed a request.')
    logging.info(req.get_json())
    orig_url = req.get_json().get('url')
    custom_hash = req.get_json().get('custom_hash')
    oid = req.get_json().get('oid')
    existing_id = req.get_json().get('existing_id')
    circuit_breaker = 0

    if not orig_url or \
        orig_url == '' or \
        not re.fullmatch(r'^https?:\/\/[\-A-Za-z0-9+&@#\/%?=~_|!:,.;]*[\-A-Za-z0-9+&@#\/%=~_|]',
                        orig_url):
        return func.HttpResponse(
            json.dumps({"message": "Provide a valid URL to shorten."}),
            mimetype='application/json',
            charset='utf-8',
            status_code=400
        )

    while True:
        if custom_hash == '':
            url_hash = generate_url_hash()
        else:
            if len(custom_hash) != 8 or not custom_hash.isalnum():
                return func.HttpResponse(
                    # pylint: disable=line-too-long
                    json.dumps({"message": "Custom hash should be 8 characters long and alphanumeric."}),
                    mimetype='application/json',
                    charset='utf-8',
                    status_code=400
                )
            url_hash = custom_hash
        circuit_breaker += 1
        try:
            db_item = db_container.read_item(item=url_hash, partition_key=url_hash)
            print(db_item)
        except exceptions.CosmosResourceNotFoundError:
            logging.info('Created a unique hash of %s', url_hash)
            try:
                db_container.create_item(
                    body={'id': url_hash, 'target_url': orig_url, 'oid': oid}
                )
                if existing_id and existing_id != '':
                    db_container.delete_item(
                        item=existing_id,
                        partition_key=existing_id
                    )
            except (exceptions.CosmosClientTimeoutError, exceptions.CosmosHttpResponseError) as err:
                logging.error(err)
                return func.HttpResponse(
                    json.dumps({"message": "Failed to generate a short URL. Try again later."}),
                    mimetype='application/json',
                    charset='utf-8',
                    status_code=500
                )
            return func.HttpResponse(
                json.dumps({"message": f"{SHORT_URL}/{url_hash}"}),
                mimetype='application/json',
                charset='utf-8',
                status_code=200
            )

        if custom_hash != '':
            return func.HttpResponse(
                json.dumps({"message": "Provided custom short URL is not available."}),
                mimetype='application/json',
                charset='utf-8',
                status_code=500
            )
        logging.info('There exist an item with hash %s, hence retrying', url_hash)
        if circuit_breaker >= 10:
            return func.HttpResponse(
                    json.dumps({"message": "Failed to generate a short URL. Try again later."}),
                    mimetype='application/json',
                    charset='utf-8',
                    status_code=500
            )
