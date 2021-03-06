# Source: https://github.com/rs-services/cos_assets
#
# Version: 3.0.1
#

[CmdletBinding()]
param(
    [System.Management.Automation.PSCredential]$RSCredential,
    [alias("ReportName")]
    [string]$CustomerName,
    [string]$Endpoint = "us-3.rightscale.com",
    [string]$OrganizationID,
    [alias("ParentAccount")]
    [string[]]$Accounts,
    [bool]$ExportToCsv = $true
)

## Store all the start up variables so you can clean up when the script finishes.
if ($startupVariables) { 
    try {
        Remove-Variable -Name startupVariables -Scope Global -ErrorAction SilentlyContinue
    }
    catch { }
}
New-Variable -force -name startupVariables -value ( Get-Variable | ForEach-Object { $_.Name } ) 

## Check Runtime environment
if($PSVersionTable.PSVersion.Major -lt 4) {
    Write-Error "This script requires at least PowerShell 4.0."
    EXIT 1
}

#if(!(Test-NetConnection -ComputerName "login.rightscale.com" -Port 443)) {
#    Write-Error "Unable to contact login.rightscale.com. Check you internet connection."
#    EXIT 1
#}

## Create functions
Function Clean-Memory {
    $scriptVariables = Get-Variable | Where-Object { $startupVariables -notcontains $_.Name }
    ForEach($scriptVariable in $scriptVariables) {
        try {
            Remove-Variable -Name $($scriptVariable.Name) -Force -Scope Global -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        }
        catch { }
    }
}

# Establish sessions with RightScale
function establish_rs_session($account) {

    $endpoint = $gAccounts["$account"]['endpoint']
    
    # Establish a session with RightScale, given an account number
    try {
        Write-Verbose "$account : Establishing a web session via $endpoint..."
        $response = Invoke-WebRequest -Uri "https://$endpoint/api/session" -Headers $headers -Method POST -SessionVariable tmpvar -ContentType application/x-www-form-urlencoded -Body "email=$($RSCredential.UserName)&password=$($RSCredential.GetNetworkCredential().Password)&account_href=/api/accounts/$account" -MaximumRedirection 0 -ErrorAction Ignore
        if($response.StatusCode -eq $null) {
            Write-Warning "$account : Unable to establish a session! StatusCode not present"
            RETURN $false
        }
        elseif($response.StatusCode -eq 204) {
            $webSessions["$account"] = $tmpvar
            RETURN $true
        }
        elseif($response.StatusCode -eq 302) {
            # Request is redirected if the incorrect endpoint is used
            $newEndpoint = $response.Headers.Location.Replace('https://','').Split('/')[0]
            Write-Verbose "$account : Request redirected to $newEndpoint"
            Write-Verbose "$account : Establishing a web session via $newEndpoint..."
            $response2 = Invoke-WebRequest -Uri "https://$newEndpoint/api/session" -Headers $headers -Method POST -SessionVariable tmpvar -ContentType application/x-www-form-urlencoded -Body "email=$($RSCredential.UserName)&password=$($RSCredential.GetNetworkCredential().Password)&account_href=/api/accounts/$account" -MaximumRedirection 0 -ErrorAction Ignore
            if($response2.StatusCode -eq 204) {
                $webSessions["$account"] = $tmpvar
                $gAccounts["$account"]['endpoint'] = $newEndpoint
                RETURN $true
            }
            else {
                Write-Warning "$account : Unable to establish a session! StatusCode: $($response2.StatusCode)"
                RETURN $false
            }
        }
        else {
            Write-Warning "$account : Unable to establish a session! StatusCode: $($response.StatusCode)"
            RETURN $false
        }
    }
    catch {
        if($_.Exception.Response.StatusCode.value__ -eq 302) {
            # Request is redirected if the incorrect endpoint is used
            $newEndpoint = $_.exception.response.headers.location.host
            Write-Verbose "$account : Request redirected to $newEndpoint"
            try {
                Write-Verbose "$account : Establishing a web session via $newEndpoint..."
                Invoke-WebRequest -Uri "https://$newEndpoint/api/session" -Headers $headers -Method POST -SessionVariable tmpvar -ContentType application/x-www-form-urlencoded -Body "email=$($RSCredential.UserName)&password=$($RSCredential.GetNetworkCredential().Password)&account_href=/api/accounts/$account" -MaximumRedirection 0 -ErrorAction Ignore
                $webSessions["$account"] = $tmpvar
                $gAccounts["$account"]['endpoint'] = $newEndpoint
                RETURN $true
            }
            catch {
                Write-Warning "$account : Unable to establish a session! StatusCode: $($_.Exception.Response.StatusCode.value__)"
                RETURN $false
            }
        }
        else {
            Write-Warning "$account : Unable to establish a session! StatusCode: $($_.Exception.Response.StatusCode.value__)"
            RETURN $false
        }
    }
}

## Prompt for missing parameters with meaningful messages and verify
if($RSCredential -eq $null) {
    $RSCredential = Get-Credential -Message "Enter your RightScale credentials"
    if($RSCredential -eq $null) {
        Write-Warning "You must enter your credentials!"
        EXIT 1
    }
}

if($CustomerName.Length -eq 0) {
    $CustomerName = Read-Host "Enter Customer/Report Name"
    if($CustomerName.Length -eq 0) {
        Write-Warning "You must supply a Customer/Report Name"
        EXIT 1
    }
}

if($Endpoint.Length -eq 0) {
    $Endpoint = Read-Host "Enter RS API endpoint (Example: us-3.rightscale.com)"
    if($Endpoint.Length -eq 0) {
        Write-Warning "You must supply an endpoint"
        EXIT 1
    }
}

if($OrganizationID.Length -eq 0) {
    $OrganizationID = Read-Host "Enter the Organization ID to gather details from all child accounts. Enter 0 or Leave blank to skip"
    if($OrganizationID.Length -eq 0) {
        $OrganizationID = 0
    }
}

if($Accounts.Count -eq 0) {
    $Accounts = Read-Host "Enter comma separated list of RS Account Number(s), or Parent Account number if Organization ID was specified (Example: 1234,4321,1111)"
    if($Accounts.Length -eq 0) {
        Write-Warning "You must supply at least 1 account!"
        EXIT 1
    }
}

## Instantiate common variables
$parent_provided = $false
$child_accounts_present = $false
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("X_API_VERSION","1.5")
$webSessions = @{}
$gAccounts = @{}
$currentTime = Get-Date
$csvTime = Get-Date -Date $currentTime -Format dd-MMM-yyyy_hhmmss

## Instantiate script specific variables
$allVolumesObject = [System.Collections.ArrayList]@()

## Start Main Script
Write-Verbose "Script Start Time: $currentTime"

# Convert the comma separated $accounts into a unique array of accounts
if($accounts -like '*,*') {
    [string[]]$accounts = $accounts.Split(",")
}

# Ensure there are no duplicates
[string[]]$accounts = $accounts.Trim() | Sort-Object | Get-Unique

## Gather all account information available and set up sessions
# Assume if only 1 account was provided, it could be a Parent(Organization) Account
# Try to collect Child(Projects) accounts
if(($accounts.Count -eq 1) -and ($OrganizationID.length -gt 0) -and ($OrganizationID -ne 0)) {
    try {
        # Assume that $accounts contains only a parent account, and attempt to extract its children
        $parentAccount = $accounts
        # Kickstart the account attributes by giving it the endpoint provided by the user
        $gAccounts["$parentAccount"] = @{'endpoint'="$endpoint"}
        # Establish a session with and gather information about the provided account
        $accountInfoResult = establish_rs_session -account $parentAccount
        if($accountInfoResult -eq $false) { EXIT 1 }
        # Attempt to pull a list of child accounts (and their account attributes)
        $response = Invoke-RestMethod -Uri "https://$($gAccounts["$parentAccount"]['endpoint'])/api/sessions?view=whoami" -Headers $headers -Method GET -WebSession $webSessions["$parentAccount"] -ContentType application/x-www-form-urlencoded
        $userId = ($response.links | Where-Object {$_.rel -eq "user"} | Select-Object -ExpandProperty href).Split('/')[-1]
        $originalAPIVersion = $webSessions["$parentAccount"].Headers["X_API_VERSION"]
        $webSessions["$parentAccount"].Headers.Remove("X_API_VERSION") | Out-Null
        $userAccessResult = Invoke-RestMethod -Uri "https://governance.rightscale.com/grs/users/$userId/projects" -Headers @{"X-API-Version"="2.0"} -Method GET -WebSession $webSessions["$parentAccount"]
        $webSessions["$parentAccount"].Headers.Remove("X-API-Version") | Out-Null
        $webSessions["$parentAccount"].Headers.Add("X_API_VERSION",$originalAPIVersion)
        $childAccountsResult = $userAccessResult | Where-Object {$_.links.org.id -eq $OrganizationID} | Where-Object {$_.id -notmatch $parentAccount}
        if($childAccountsResult.count -gt 0) {
            $childAccounts = [System.Collections.ArrayList]@()
            $child_accounts_present = $true
            # Organize and store child account attributes
            foreach($childAccountResult in $childAccountsResult) {
                $accountNum = $childAccountResult.id
                $accountEndpoint = $childAccountResult.legacy.account_url.replace('https://','').split('/')[0]
                $gAccounts["$accountNum"] += @{
                    'endpoint'=$accountEndpoint
                }
                # Establish sessions with and gather information about all of the child accounts individually
                $childAccountInfoResult = establish_rs_session -account $accountNum
                if($childAccountInfoResult -eq $false) {
                    # To continue, we need to remove it from the hash
                    $gAccounts.Remove("$accountNum")
                }
                else {
                    #Otherwise add it to the childAccounts array
                    $childAccounts += $accountNum
                }
            }
            # If anything had errored out prior to here, we would not get to this line, so we are confident that we were provided a parent account
            $parent_provided = $true
            # Add the newly enumerated child accounts back to the list of accounts
            $accounts = $gAccounts.Keys
            if($childAccounts.Count -gt 0) {
                Write-Verbose "$parentAccount : Child accounts have been identified: $childAccounts"
            }
            else {
                Write-Warning "$parentAccount : Child accounts have been identified, but they could not be authenticated to"
            }
        }
        else {
            # No child accounts
            $parent_provided = $false
            $child_accounts_present = $false
            Write-Verbose "$parentAccount : No child accounts identified."
        }
    } catch {
        # Issue while attempting to pull child accounts, assume this is not a parent account
        $parent_provided = $false
        $child_accounts_present = $false
        Write-Verbose "$parentAccount : No child accounts identified."
    }
}

if(!$parent_provided -and $accounts.count -gt 0) {
    # We were provided multiple accounts, or the single account we got wasn't a parent
    foreach ($account in $accounts) {
        if(!($webSessions["$account"])) {
            # Kickstart the account attributes by giving it the endpoint provided by the user
            $gAccounts["$account"] = @{'endpoint'="$endpoint"}

            # Attempt to establish sessions with the provided accounts and gather the relevant information
            $accountInfoResult = establish_rs_session -account $account
            if($accountInfoResult -eq $false) {
                # To continue, we need to remove it from the hash and the array
                $gAccounts.Remove("$account")
                $accounts = $accounts | Where-Object {$_ -ne $account}
            }
        }
    }
}

if($gAccounts.Keys.count -eq 0) {
    Write-Warning "No accounts left to use!"
    EXIT 1
}

foreach ($account in $gAccounts.Keys) {
    Write-Verbose "$account : Starting..."

    # Account Name
    try {
        $accountName = Invoke-RestMethod -Uri "https://$($gAccounts["$account"]['endpoint'])/api/accounts/$account" -Headers $headers -Method GET -WebSession $webSessions["$account"] | Select-Object -ExpandProperty name
    }
    catch {
        Write-Warning "$account : Unable to retrieve account name! StatusCode: $($_.Exception.Response.StatusCode.value__)"
        $accountName = "Unknown"
    }

    # Get Clouds
    try {
        $clouds = Invoke-RestMethod -Uri "https://$($gAccounts["$account"]['endpoint'])/api/clouds?account_href=/api/accounts/$account" -Headers $headers -Method GET -WebSession $webSessions["$account"]
    } 
    catch {
        Write-Warning "$account : Unable to retrieve clouds! StatusCode: $($_.Exception.Response.StatusCode.value__)"
        CONTINUE
    }

    if((($clouds.display_name -like "AWS*").count -gt 0) -or
        (($clouds.display_name -like "Azure*").count -gt 0) -or
        (($clouds.display_name -like "Google*").count -gt 0)){
        # Account has AWS, Azure, or Google connected, get the Account ID
        Write-Verbose "$account : AWS, Azure, or Google Clouds Connected - Retrieving Account IDs..."
        $originalAPIVersion = $webSessions["$account"].Headers["X_API_VERSION"]
        $webSessions["$account"].Headers.Remove("X_API_VERSION") | Out-Null
        
        try {
            $cloudAccounts = Invoke-RestMethod -Uri "https://$($gAccounts["$account"]['endpoint'])/api/cloud_accounts" -Headers @{"X-Api-Version"="1.6";"X-Account"=$account} -Method GET -WebSession $webSessions["$account"]
        }
        catch {
            Write-Warning "$account : Unable to retrieve cloud account IDs! StatusCode: $($_.Exception.Response.StatusCode.value__)"
        }

        $webSessions["$account"].Headers.Remove("X-Api-Version") | Out-Null
        $webSessions["$account"].Headers.Remove("X-Account") | Out-Null
        $webSessions["$account"].Headers.Add("X_API_VERSION",$originalAPIVersion)

        if($cloudAccounts){
            $cloudAccountIds = $cloudAccounts | Select-Object @{Name='href';Expression={$_.links.cloud.href}},tenant_uid
        }
    }
    else {
        $cloudAccountIds = $null
    }
    
    foreach ($cloud in $clouds) {
        $cloudName = $cloud.display_name
        $cloudHref = $cloud.links | Where-Object {$_.rel -eq 'self'} | Select-Object -ExpandProperty href

        if($cloudName -like "AzureRM*") {
            try {
                $volumeTypes = Invoke-RestMethod -Uri "https://$($gAccounts["$account"]['endpoint'])$($cloud.links | Where-Object { $_.rel -eq 'volume_types' } | Select-Object -ExpandProperty href)" -Headers $headers -Method GET -WebSession $webSessions["$account"]
            }
            catch {
                Write-Warning "$account : $cloudName : Unable to retrieve volumes types! StatusCode: $($_.Exception.Response.StatusCode.value__)"
            }
            $volumeTypes = $volumeTypes | Select-Object name, resource_uid, @{n='href';e={$_.links | Where-Object {$_.rel -eq 'self'}| Select-Object -ExpandProperty href}}
        }

        if ($($cloud.links | Where-Object { $_.rel -eq 'volumes'})) {                                                                              
            $volumes = @()
            Write-Verbose "$account : $cloudName : Getting Volumes..."

            try {
                $volumes = Invoke-RestMethod -Uri "https://$($gAccounts["$account"]['endpoint'])$cloudHref/volumes?view=extended" -Headers $headers -Method GET -WebSession $webSessions["$account"]
            }
            catch {
                Write-Warning "$account : $cloudName : Unable to retrieve volumes! StatusCode: $($_.Exception.Response.StatusCode.value__)"
                CONTINUE
            }

            if(!($volumes)) {
                Write-Verbose "$account : $cloudName : No Volumes Found!"
                CONTINUE
            }
            else {
                foreach ($volume in $volumes) {
                    if (($volume.status -eq "available") -and ($volume.resource_uid -notlike "*system@Microsoft.Compute/Images/*") -and ($volume.resource_uid -notlike "*@images*")) {
                        Write-Verbose "$account : $cloudName : $($volume.name) : Unattached"
                        $volumeHref = $($volume.links | Where-Object rel -eq "self").href
                        try {
                            $volumeTags = Invoke-RestMethod -Uri https://$($gAccounts["$account"]['endpoint'])/api/tags/by_resource -Headers $headers -Method POST -WebSession $webSessions["$account"] -ContentType application/x-www-form-urlencoded -Body "email=$($RSCredential.UserName)&password=$($RSCredential.GetNetworkCredential().Password)&account_href=/api/accounts/$account&resource_hrefs[]=$volumeHref"
                        }
                        catch {
                            Write-Warning "$account : $cloudName : $($volume.name) : Unable to retrieve Volume tags! StatusCode: $($_.Exception.Response.StatusCode.value__)"
                        }
                        
                        if($cloudName -like "AzureRM*") {
                            $volumeTypeHref = $volume.links | Where-Object { $_.rel -eq "volume_type" } | Select-Object -ExpandProperty href
                            $placementGroupHref = $volume.links | Where-Object { $_.rel -eq "placement_group" } | Select-Object -ExpandProperty href
                            
                            if($placementGroupHref) {
                                $placementGroupTags = @()
                                $armDiskType = "Unmanaged"
                                try {
                                    $placementGroup = Invoke-RestMethod -Uri "https://$($gAccounts["$account"]['endpoint'])$($placementGroupHref)?view=extended" -Headers $headers -Method GET -WebSession $webSessions["$account"]
                                }
                                catch {
                                    Write-Warning "$account : $cloudName : $($volume.name) : Unable to retrieve Placement Group! StatusCode: $($_.Exception.Response.StatusCode.value__)"
                                }
                                
                                if ($placementGroup) {
                                    $armStorageType = $placementGroup.cloud_specific_attributes.account_type
                                    $armResourceGroup = $placementGroup.cloud_specific_attributes.'Resource Group'
                                    try {
                                        $placementGroupTags = Invoke-RestMethod -Uri https://$($gAccounts["$account"]['endpoint'])/api/tags/by_resource -Headers $headers -Method POST -WebSession $webSessions["$account"] -ContentType application/x-www-form-urlencoded -Body "email=$($RSCredential.UserName)&password=$($RSCredential.GetNetworkCredential().Password)&account_href=/api/accounts/$account&resource_hrefs[]=$placementGroupHref"
                                    }
                                    catch {
                                        Write-Warning "$account : $cloudName : $($volume.name) : Unable to retrieve Placement Group tags! StatusCode: $($_.Exception.Response.StatusCode.value__)"
                                    }
                                }
                                else {
                                    Write-Warning "$account : $cloudName : $($volume.name) : Unable to retrieve Placement Group!"
                                    $armStorageType = "ERROR"
                                    $armResourceGroup = "Unknown"
                                }
                                $armStorageAccountName = $volume.placement_group.name
                                $volumeTags = $volumeTags + $placementGroupTags
                            }
                            elseif($volumeTypeHref) {
                                $armDiskType = "Managed"
                                $armStorageType = $volumeTypes | Where-Object { $_.href -eq $volumeTypeHref } | Select-Object -ExpandProperty name
                                $armResourceGroup = "Unknown"
                                $armStorageAccountName = "N/A"
                            }
                            else {
                                $armDiskType = "Unknown"
                                $armStorageType = "Unknown"
                                $armStorageAccountName = "Unknown"
                                $armResourceGroup = "Unknown"
                            }
                        }
                        elseif ($cloudName -like "Azure*") {
                            $armDiskType = "Unmanaged"
                            $armStorageType = "Classic"
                            $armStorageAccountName = $volume.placement_group.name
                            $armResourceGroup = "N/A"

                            if(!($armStorageAccountName)) {
                                $armStorageAccountName = "Unknown"
                            }
                        }
                        else {
                            $armDiskType = "N/A"
                            $armStorageType = "N/A"
                            $armStorageAccountName = "N/A"
                            $armResourceGroup = "N/A"
                        }

                        $object = [pscustomobject]@{
                            "Account_ID"                = $account;
                            "Account_Name"              = $accountName;
                            "Cloud_Account_ID"          = $($cloudAccountIds | Where-Object {$_.href -eq $cloudHref} | Select-Object -ExpandProperty tenant_uid);
                            "Cloud"                     = $cloudName;
                            "Volume_Name"               = $volume.name;
                            "Description"               = $volume.description;
                            "Resource_UID"              = $volume.resource_uid;
                            "Volume_Type_Href"          = $volume.volume_type_href;
                            "IOPS"                      = $volume.iops;
                            "Size"                      = $volume.size;
                            "Status"                    = $volume.status;
                            "Azure_Disk_Type"           = $armDiskType;
                            "Azure_Storage_Type"        = $armStorageType;
                            "Azure_Storage_Account"     = $armStorageAccountName;
                            "Azure_Resource_Group"      = $armResourceGroup;
                            "Created_At"                = $volume.created_at;
                            "Updated_At"                = $volume.updated_at;
                            "Cloud_Specific_Attributes" = $volume.cloud_specific_attributes;
                            "Href"                      = $volumeHref;
                            "Tags"                      = "`"$($volumeTags.tags.name -join '","')`"";
                        }
                        $allVolumesObject += $object
                    }
                    else {
                        Write-Verbose "$account : $cloudName : $($volume.name) - $($volume.resource_uid) : Attached"
                    }
                }
            }
        }
    }
}

if ($allVolumesObject.count -gt 0){
    if($ExportToCsv) {
        $csv = "$($CustomerName)_UnattachedVolumes_$($csvTime).csv"
        $allVolumesObject | Export-Csv "./$csv" -NoTypeInformation
        $csvFilePath = (Get-ChildItem $csv).FullName
        Write-Host "CSV File: $csvFilePath"
    }
    else {
        $allVolumesObject
    }
}
else {
    Write-Host "No Unattached Volumes Found!"
}

if(($DebugPreference -eq "SilentlyContinue") -or ($PSBoundParameters.ContainsKey('Debug'))) {
    ## Clear out any variables that were created
    # Useful for testing in an IDE/ISE, shouldn't be necesary for running the script normally
    Write-Verbose "Clearing variables from memory..."
    Clean-Memory
}

$scriptEndTime = Get-Date 
$scriptElapsed = New-TimeSpan -Start $currentTime -End $scriptEndTime
$scriptElapsedMinutes = "{00:N2}" -f $scriptElapsed.TotalMinutes
Write-Verbose "Script End Time: $scriptEndTime"
Write-Verbose "Script Elapsed Time: $scriptElapsedMinutes minute(s)"
