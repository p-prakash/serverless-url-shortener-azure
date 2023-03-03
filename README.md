# Serverless URL Shortener on Azure

This is an example implementation of URL Shortener using Serverless technologies in Azure. Check out [the accompanying blog](https://pprakash.me/tech/2023/02/20/serverless-url-shortener-azure/) for the details about the implementation.

## Prerequisites

* Active Azure Subscription
* GitHub account and Personal Access Token (PAT) with scope to create repository, create actions, and create secrets. [Learn more](https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token)
* Azure AD permissions to create RBAC Role, CosmosDB, API Managment, Azure functions, Storage Account, Azure Front Door, and other dependent services
* Ability to login to Azure using browser
* Latest version of [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) and [Azure Function Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local) installed
* Python version 3.9+ installed and create a Virtual environment to execute the deployment script
* Existing Azure AD B2C tenant (Step by step guide can be found in [this documentation](https://learn.microsoft.com/en-us/azure/api-management/howto-protect-backend-frontend-azure-ad-b2c))

  * Create 2 app registrations for Single Page Application (SPA) and API
  * Create a Sign Up and Sign In user flow

## Repository content

* `config.yaml` - Configuration file which you need to update to provide the required parameters
* `deploy.py` - Deployment script which will deploy this solution in your Azure Subscription
* `url-shortener.bicep` - Bicep template which creates required infrastructure in Azure
* `main.bicep` - Main Bicep template which creates a new Resource Group and create the resources from the `url-shortener` module
* `dns-records.bicep` - Bicep template which creates DNS records in Azure DNS
* `function_code` - Azure Functions source code to create short URL
* `frontend/index-template.html` - HTML template for the Single Page Application (SPA) which will be updated with appropriate values deployed by Bicep
* `frontend/link-checker-template.html` - HTML template for the Link Checker page which will be updated with appropriate values deployed by Bicep

## Configuration

You need to update the config.yaml with appropriate values for the deployment script to deploy the right resources.

|Parameter name|Description|Example|
|:---|---:|---|
|**environment**|Name of the environment|`prod`|
|**location**|Azure region where the solution needs to be deployed|`westeurope`|
|**subscription**|Azure Subscription ID where the solution needs to be deployed|`7example-abcd-1234-pqrs-examplec5db2`|
|**aadB2cOrg**|Azure AD B2C Tenant Name|`suruku`|
|**aadB2cUserFlow**|Azure AD B2C User Flow Name for Sign Up and Sign In|`B2C_1_us_sisu`|
|**aadB2cApiClientId**|Azure AD B2C App Client Id of API|`bexample-abcd-1234-pqrs-examplef9a45`|
|**aadB2cSpaClientId**|Azure AD B2C App Client Id of Single Page Application (SPA)|`fexample-abcd-1234-pqrs-example6cd6a`|
|**shortUrl**|URL that should be used for shorterning (Include `https://` and the training slash`/`)|`https://suru.ku/`|
|**writeScope**|Write scope for API in Azure AD B2C|`https://suruku.onmicrosoft.com/shorten-url/API.Write`|
|**readScope**|Read scope for API in Azure AD B2C|`https://suruku.onmicrosoft.com/shorten-url/API.Read`|
|**dnsZone**|Azure DNS Zone Name *Optional*|`suru.ku`|
|**dnsZoneRG**|Azure DNS Zone Resource Group Name *Optional*|`Suruku-DNS-RG`|

## Deployment

Make sure you have cloned the repository and navigate inside the repository directory. If you haven't already created a [python virtual environment](https://docs.python.org/3/library/venv.html), create one as the deployment script requires a virtual environment and activate it.

After updating the `config.yaml` run the following command to deploy the solution

```shell
python deploy.py
```

Review the prompts and confirm the subscription ID to start the deployment. Once the deployment has been completed you should add the following URI  ([Your Short URL]/url-shortener/index.html - e.g. `https://suru.ku/`) in redirect URI section of SPA app client registration in your Azure AD B2C tenant. In case if you don't have a domain and just want to test the solution you can use the Azure Front Door endpoint URL in the redirect URI (e.g. `https://us-cdn-ep-example-babcdbdxyzb1234q.z01.azurefd.net/`). Front Door endpoint URL will be printed after the successful deployment of the above script.
