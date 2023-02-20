'''Script to deploy the application to Azure'''
# pylint: disable=wrong-import-position

import os
import sys
import json
import platform
import subprocess
import importlib.metadata
from time import sleep
from urllib.request import urlopen
from datetime import datetime, timedelta

# Define colors to print in the console
BLUE = '\033[94m'
CYAN = '\033[96m'
OKGREEN = '\033[92m'
WARNING = '\033[93m'
FAIL = '\033[91m'
ENDC = '\033[0m'
BOLD = '\033[1m'
UNDERLINE = '\033[4m'

os.system('color')
if sys.prefix == sys.base_prefix:
    print(f'{WARNING}This is not a virtual environment!{ENDC}')
    print('Run the following command to create a virtual environment')
    print(f'{BOLD}{CYAN}python -m venv venv{ENDC}')
    print('Then activate the virtual environment')
    if platform.system() == 'Windows':
        # pylint: disable=anomalous-backslash-in-string
        print(f'{BOLD}{CYAN}venv\Scripts\\activate{ENDC}')
    elif platform.system() == 'Linux':
        print(f'{BOLD}{CYAN}source venv/bin/activate{ENDC}')
    else:
        print(f'{BOLD}{FAIL}Unsupported platform{ENDC}')
    print('Then run the deploy.py script again')
    sys.exit()
else:
    print(f'{BOLD}{BLUE}We are in a virtual environment{ENDC}')
    required = ['azure-cli', 'pyyaml']
    for pkg in required:
        print(f'Checking for {pkg}...')
        try:
            importlib.metadata.version(pkg)
        except importlib.metadata.PackageNotFoundError:
            subprocess.check_call([sys.executable, '-m', 'pip', 'install', pkg])

    import yaml
    from azure.cli.core import get_default_cli

    with open('config.yaml', encoding='utf-8') as c:
        config = yaml.safe_load(c)

    subscription_id = config['subscription']

    az_cli = get_default_cli()
    # Confirm subscription Id
    CONFIRM_FLAG = True
    ATTEMPT = 0
    while CONFIRM_FLAG:
        ATTEMPT += 1
        # pylint: disable=line-too-long
        print(f'Confirm whether you want to deploy to the subscription with Id: {BLUE}{subscription_id}{ENDC}')
        choice = input('Enter y to continue or n to exit: ').lower()
        if choice == 'y':
            CONFIRM_FLAG = False
        elif choice == 'n':
            sys.exit()
        else:
            if ATTEMPT == 3:
                print(f'{BOLD}{FAIL}Invalid input. Exiting...{ENDC}')
                sys.exit()
            print(f'{WARNING}Invalid input. Please enter y or n{ENDC}')

    # Checking whether logged in to Azure CLI
    account_response = az_cli.invoke(['account', 'show', '--subscription', subscription_id])
    if account_response == 0:
        subscription_name = az_cli.result.result['name']
        # pylint: disable=line-too-long
        print(f'Going to deploy in subscription: {BOLD}{subscription_name}{ENDC} with Id: {BOLD}{subscription_id}{ENDC}')
    else:
        print('You are not logged in to Azure CLI. Attempting to login...')
        az_cli.invoke(['login'])
        az_cli.invoke(['account', 'set', '--subscription', subscription_id])

    # Deploy the backend infrastructure
    print('Deploying the backend infrastructure in Azure...')
    bicep_parameters = {
        'Environ': {'value': config['environment']},
        'location': {'value': config['location']},
        'aadB2cOrg': {'value': config['aadB2cOrg']},
        'aadB2cUserFlow': {'value': config['aadB2cUserFlow']},
        'aadB2cApiClientId': {'value': config['aadB2cApiClientId']},
        'shortUrl': {'value': config['shortUrl']}
    }
    az_cli.invoke(['deployment',
                    'sub',
                    'create',
                    '-n',
                    'test-deploy-2',
                    '-l',
                    config['location'],
                    '--template-file',
                    'main.bicep',
                    '--parameters',
                    json.dumps(bicep_parameters)
                    ])

    if not az_cli.result.result['properties']['error']:
        print(f'{OKGREEN}Successfully deployed the backend infrastructure{ENDC}')
        frontend_url = az_cli.result.result['properties']['outputs']['applicationURL']['value']
        api_url = az_cli.result.result['properties']['outputs']['apiEndpoint']['value']
        storage_account = az_cli.result.result['properties']['outputs']['storageAccount']['value']
        resource_group = az_cli.result.result['properties']['outputs']['resourceGroup']['value']
        function_app = az_cli.result.result['properties']['outputs']['functionApp']['value']
    else:
        # pylint: disable=line-too-long
        print(f'{BOLD}{FAIL}Failed to deploy the backend infrastructure. Review the error message below{ENDC}')
        print(az_cli.result.result)
        sys.exit(-1)

    # Update the index.html file with the correct values
    print('Updating the index.html file...')
    with open('index-template.html', 'r', encoding='utf-8') as f:
        template = f.read()
        template = template.replace('[API_ENDPOINT]', f'{config["shortUrl"].rstrip("/")}/api')
        template = template.replace('[SHORT_URL]', config['shortUrl'])
        template = template.replace('[SPA_CLIENT_ID]', config['aadB2cSpaClientId'])
        template = template.replace('[B2C_ORG]', config['aadB2cOrg'])
        template = template.replace('[B2C_USER_FLOW]', config['aadB2cUserFlow'])
        # pylint: disable=line-too-long
        template = template.replace('[FRONTEND_URL]', f'{config["shortUrl"].rstrip("/")}/url-shortener/index.html')
        template = template.replace('[WRITE_SCOPE]', config['writeScope'])
        template = template.replace('[READ_SCOPE]', config['readScope'])

    with open('index.html', 'w', encoding='utf-8') as file:
        file.write(template)

    # Approve storage account private endpoint connection
    print('Approving storage account private endpoint connection...')
    # pylint: disable=line-too-long
    get_connection = az_cli.invoke(['storage',
                                    'account',
                                    'show',
                                    '-n',
                                    storage_account,
                                    '--query',
                                    'privateEndpointConnections[*].{Id: id, Description: privateLinkServiceConnectionState.description}[?Description==`Enable Private Link for URL Shortener Origin`].Id',
                                    '-o',
                                    'tsv'])
    connection_id = az_cli.result.result
    approve_conn = az_cli.invoke(['network', 'private-endpoint-connection', 'approve', '--id', connection_id[0]])
    if approve_conn == 0:
        print(f'{OKGREEN}Connection approved{ENDC}')
    else:
        print(f'{BOLD}{FAIL}Connection approval failed. Review the error message below and approve the connection manually{ENDC}')
        print(az_cli.result.result)

    # Approve access to storage account from your IP address
    print('Approving access to storage account from your IP address...')
    # Get your IP address
    with urlopen('https://api.ipify.org') as response:
        ip_address = response.read().decode('utf-8')
        print(f'Your IP address is {BOLD}{ip_address}{ENDC}')

    approve_ip = az_cli.invoke(['storage',
                                'account',
                                'network-rule',
                                'add',
                                '-n',
                                storage_account,
                                '--ip-address',
                                ip_address
                                ])
    if approve_ip == 0:
        print(f'{OKGREEN}Added access to your IP address{ENDC}')
        print('Sleeping for 30 seconds to allow the access to take effect...')
        sleep(30)
        # Upload the index.html file to the storage account
        expiry_date = datetime.now() + timedelta(days=1)
        upload_result = az_cli.invoke(['storage',
                                        'blob',
                                        'upload',
                                        '--account-name',
                                        storage_account,
                                        '-c',
                                        'url-shortener',
                                        '-f',
                                        'index.html',
                                        '-n',
                                        'index.html',
                                        '--overwrite'
                                        ])
        if upload_result == 0:
            print('Upload successful')
            print(f'{OKGREEN}Now you can access the application from the following URL {frontend_url}/url-shortener/index.html{ENDC}')
        else:
            print(f'{FAIL}Upload failed{ENDC}')
            print(az_cli.result.result)
            print('You can upload the index.html file manually from the Azure portal')
    else:
        print(f'{FAIL}Adding access to your IP address failed{ENDC}')
        print(az_cli.result.result['properties']['error'])
        print('You can add access to your IP address manually from the Azure portal')
        print(f'Then upload the index.html file manually to the container "url-shortener" in the storage account {storage_account}')

    # Deploy the Azure Function code
    print('Deploying the Azure Function code...')
    os.chdir('function_code')
    try:
        subprocess.check_call(['func', 'azure', 'functionapp', 'publish', function_app, '--nozip'])
        print(f'{OKGREEN}Successfully deployed the Azure Function code{ENDC}')
    except subprocess.CalledProcessError as e:
        print(f'{FAIL}Failed to deploy the Azure Function code{ENDC}')
        print(e)
        # pylint: disable=line-too-long
        print('You can deploy the Azure Function code manually using Azure CLI or Azure Function Core Tools')

    print('Before logging in to the application, you need to add redirect URI in the Azure AD B2C SPA application')
    print(f'The redirect URI is the following: {BLUE}{frontend_url}/url-shortener/index.html{ENDC}')
    print('Refer this documentation for more information: https://learn.microsoft.com/en-us/azure/active-directory/develop/scenario-spa-app-registration#redirect-uri-msaljs-20-with-auth-code-flow')
    print(f'Management URL: {BOLD}{UNDERLINE}{CYAN}{frontend_url}/url-shortener/index.html{ENDC}')
    print(f'API Management URL: {BOLD}{UNDERLINE}{CYAN}{api_url}{ENDC}')
