'''Script to deploy the application to Azure'''
# pylint: disable=wrong-import-position

import os
import sys
import json
import string
import secrets
import platform
import subprocess
import importlib.metadata
from getpass import getpass
from urllib.parse import quote_plus

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
    required = ['azure-cli', 'pyyaml', 'PyGithub', 'pypiwin32']
    for pkg in required:
        print(f'Checking for {pkg}...')
        try:
            importlib.metadata.version(pkg)
        except importlib.metadata.PackageNotFoundError:
            subprocess.check_call([sys.executable, '-m', 'pip', 'install', pkg])

    import yaml
    from azure.cli.core import get_default_cli
    from github import Github

    with open('config.yaml', encoding='utf-8') as c:
        config = yaml.safe_load(c)

    subscription_id = config['subscription']
    SUFFIX = ''.join(secrets.choice(string.ascii_letters + string.digits) for i in range(8))

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

    # Get GitHub access token
    gh_access_token = getpass(prompt='Enter the GitHub access token to create the repository:')
    if not gh_access_token:
        print(f'{BOLD}{FAIL}GitHub access token is required. Exiting...{ENDC}')
        sys.exit()

    # Create GitHub repository and add the index.html file
    print('Creating GitHub repository...')
    REPO_NAME = f'url-shortener-{SUFFIX}'
    gh = Github(gh_access_token)
    repo = gh.get_user().create_repo(REPO_NAME)
    print(f'{OKGREEN}Created the GitHub repository - {repo.full_name}{ENDC}')

    # Checking whether logged in to Azure CLI
    account_response = az_cli.invoke(['account',
                                      'show',
                                      '--subscription',
                                      subscription_id,
                                      '--output',
                                      'none'])
    if account_response == 0:
        subscription_name = az_cli.result.result['name']
        # pylint: disable=line-too-long
        print(f'Going to deploy in subscription: {BOLD}{subscription_name}{ENDC} with Id: {BOLD}{subscription_id}{ENDC}')
    else:
        print('You are not logged in to Azure CLI. Attempting to login...')
        az_cli.invoke(['login'])
        az_cli.invoke(['account', 'set', '--subscription', subscription_id, '--output', 'none'])

    # Deploy the backend infrastructure
    print('Deploying the backend infrastructure in Azure...')
    print(f'{BOLD}It will take few minutes to get completed...{ENDC}')
    bicep_parameters = {
        'Environ': {'value': config['environment']},
        'location': {'value': config['location']},
        'aadB2cOrg': {'value': config['aadB2cOrg']},
        'aadB2cUserFlow': {'value': config['aadB2cUserFlow']},
        'aadB2cApiClientId': {'value': config['aadB2cApiClientId']},
        'shortUrl': {'value': config['shortUrl']},
        'repoURL': {'value': repo.html_url},
        'repoToken': {'value': gh_access_token},
        'suffix': {'value': SUFFIX}
    }
    if 'dnsZone' in config and 'dnsZoneRG' in config:
        bicep_parameters['dnsZone'] = {'value': config['dnsZone']}
        bicep_parameters['dnsZoneRG'] = {'value': config['dnsZoneRG']}

    az_cli.invoke(['deployment',
                    'sub',
                    'create',
                    '-n',
                    'url-shortener-main',
                    '-l',
                    config['location'],
                    '--template-file',
                    'main.bicep',
                    '--parameters',
                    json.dumps(bicep_parameters),
                    '--output',
                    'none'
                    ])

    if az_cli.result.result and \
        'properties' in az_cli.result.result and \
        not az_cli.result.result['properties']['error']:
        print(f'{OKGREEN}Successfully deployed the backend infrastructure{ENDC}')
        function_app = az_cli.result.result['properties']['outputs']['functionApp']['value']
    else:
        # pylint: disable=line-too-long
        print(f'{BOLD}{FAIL}Failed to deploy the backend infrastructure. Review the error message below{ENDC}')
        print(az_cli.result.result)
        sys.exit(-1)

    # Update the index.html file with the correct values
    print('Updating the index.html file...')
    with open('frontend/index-template.html', 'r', encoding='utf-8') as f:
        index_html = f.read()
        index_html = index_html.replace('[API_ENDPOINT]', f'{config["shortUrl"].rstrip("/")}/api')
        index_html = index_html.replace('[SHORT_URL]', config['shortUrl'])
        index_html = index_html.replace('[SPA_CLIENT_ID]', config['aadB2cSpaClientId'])
        index_html = index_html.replace('[B2C_ORG]', config['aadB2cOrg'])
        index_html = index_html.replace('[B2C_USER_FLOW]', config['aadB2cUserFlow'])
        index_html = index_html.replace('[ENCODED_URL]', quote_plus(config["shortUrl"]))
        # pylint: disable=line-too-long
        index_html = index_html.replace('[FRONTEND_URL]', f'{config["shortUrl"].rstrip("/")}/')
        index_html = index_html.replace('[WRITE_SCOPE]', config['writeScope'])
        index_html = index_html.replace('[READ_SCOPE]', config['readScope'])

    with open('frontend/index.html', 'w', encoding='utf-8') as file:
        file.write(index_html)

    print('Updating the link-checker.html file...')
    with open('frontend/link-checker-template.html', 'r', encoding='utf-8') as f:
        link_checker = f.read()
        # pylint: disable=anomalous-backslash-in-string
        url_pattern = config["shortUrl"].rstrip('/').replace('/', '\/').replace('.','\.')
        url_pattern += '\/[A-Za-z0-9]{8}'
        link_checker = link_checker.replace('[URL_PATTERN]', url_pattern)

    with open('frontend/link-checker.html', 'w', encoding='utf-8') as file:
        file.write(link_checker)

    print('Uploading the static web app code to the GitHub repository...')
    repo.create_file('index.html', 'Adding index.html file', index_html, branch='main')
    repo.create_file('link-checker.html',
                     'Adding link-checker.html file',
                     link_checker,
                     branch='main'
                     )
    print(f'{OKGREEN}Uploaded the content to GitHub Repo{ENDC}')
    print(f'Check the deployment status at GitHub Actions: {repo.html_url}/actions')

    # Deploy the Azure Function code
    print('Deploying the Azure Function code...')
    os.chdir('function_code')
    try:
        subprocess.check_call(['func',
                               'azure',
                               'functionapp',
                               'publish',
                               function_app,
                               '--nozip'
                               ])
        print(f'{OKGREEN}Successfully deployed the Azure Function code{ENDC}')
    except subprocess.CalledProcessError as e:
        print(f'{FAIL}Failed to deploy the Azure Function code{ENDC}')
        print(e)
        # pylint: disable=line-too-long
        print('You can deploy the Azure Function code manually using Azure CLI or Azure Function Core Tools')

    # pylint: disable=line-too-long
    print('Before logging in to the application, you need to add redirect URI in the Azure AD B2C SPA application')
    print(f'The redirect URI is the following: {BLUE}{config["shortUrl"]}{ENDC}')
    # pylint: disable=line-too-long
    print('Refer this documentation for more information: https://learn.microsoft.com/en-us/azure/active-directory/develop/scenario-spa-app-registration#redirect-uri-msaljs-20-with-auth-code-flow')
    print(f'Management URL: {BOLD}{UNDERLINE}{CYAN}{config["shortUrl"]}{ENDC}')
