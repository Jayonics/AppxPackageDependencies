Set-Location -Path:$PSScriptRoot

enum Ring {
    RP
    Retail
    Slow
    Fast
}

enum RequestType {
    Url
    ProductId
    PackageFamilyName
    CategoryID
}

class MsStorePackage {
    [uri]$Url
    [System.IO.FileInfo]$Filename
}


function Get-MicrosoftStoreAssets {
    [CmdletBinding(DefaultParameterSetName = 'PackageFamilyName')]
    param(
        [Parameter(ParameterSetName = 'PackageFamilyName', Mandatory = $true)]
        [string]$PackageFamilyName,
        [Parameter(ParameterSetName = 'Url', Mandatory = $true)]
        [Uri]$Url,
        [Parameter(Mandatory = $false)]
        [Ring]$Ring = 'RP',
        # By default this function throws an error if the list of files is empty, otherwise it permits the function to return an empty list and outputs a warning
        [Parameter(Mandatory = $false)]
        [Switch]$AllowNoItems = $false
    )
    # If the PackageFamilyName parameter is used, get the URL from the rg-adguard API
    switch ($PSCmdlet.ParameterSetName) {
        'PackageFamilyName' {
            # Set the ProgressPreference Variable to mitigate slow downloads with Invoke-Webrequest [1]
            $ProgressPreference = 'SilentlyContinue'
            # Form the URI to get the URL from the rg-adguard API
            $ApiReponse = Invoke-WebRequest `
            -Method:Post `
            -Uri 'https://store.rg-adguard.net/api/GetFiles' `
            -Body "type=$($PSCmdlet.ParameterSetName)&url=$PackageFamilyName&ring=$Ring" `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing

            # Parse the response to get the files and URLs
            $Items = @()
            # Create a custom object to store the filename and download URL
            for($i = 0;$i -lt $ApiReponse.Links.Count; $i++) {
                if ($ApiReponse.Links[$i] -like '*.appx*' -or $ApiReponse.Links[$i] -like '*.msix*'){
                    if ($ApiReponse.Links[$i] -like '*_neutral_*' -or $ApiReponse.Links[$i] -like "*_"+$env:PROCESSOR_ARCHITECTURE.Replace("AMD","X").Replace("IA","X")+"_*"){
                        $MsStorePackage = [MsStorePackage]::new()
                        $MsStorePackage.Url = ($ApiReponse.Links[$i] | Select-String -Pattern '(?<=a href=").+(?=" r)').Matches.Value
                        $MsStorePackage.Filename = ($ApiReponse.Links[$i] | Select-String -Pattern '(?<=noreferrer">).+(?=</a>)').Matches.Value
                        $Items += $MsStorePackage
                    }
                }
            }
        }

        'Url' {
            Write-Debug "Not yet implemented"
        }
        Default {
            Write-Warning -Message "Unknown Parameter Set: $($PSCmdlet.ParameterSetName)"
            return
        }
    }

    # Depending on the AllowNoItems switch, either throw an error or output a warning if the list of items is empty
    if($Items.Count -eq 0) {
        if($AllowNoItems) {
            Write-Warning -Message "No Items found! However the AllowNoItems switch was used, continuing..."
            return $Items
        } else {
            Write-Error -Message "No items found!"
            throw
        }
    } else {
        return $Items
    }
}

function Invoke-MsStorePackageDownload {
    [CmdletBinding()]
    param (
        # Array of MsstorePackage instances.
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [MsStorePackage[]]$Packages,
        [Parameter(Mandatory=$true)]
        [System.IO.DirectoryInfo]$Directory,
        [Parameter(Mandatory=$true)]
        [String]$AppFileextension,
        [Parameter(Mandatory=$false)]
        [String]$DependencyFileextension
    )
    # Create the DownloadDirectory if it doesn't exist
    if ($Directory.Exists -eq $false) {
        Write-Host -ForegroundColor:Yellow "$($Directory.Name) doesn't exist... Creating..."
        [System.IO.DirectoryInfo]$Directory = New-Item -Path $Directory -ItemType Directory -Force
    } else {
        Write-Host -ForegroundColor:Yellow "$($Directory.Name) already exists..."
    }
    # Download the packages
    foreach($Package in $Packages) {
        Write-Host -ForegroundColor:Blue "Downloading: $($Package.FileName)"
        #Write-Host -ForegroundColor:Yellow "Uri: $($Package.Url)"
        Write-Host -ForegroundColor:Magenta "Destination: $(($Directory).FullName)\$($Package.Filename)"
        # Set the ProgressPreference Variable to mitigate slow downloads with Invoke-Webrequest [2]
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri:$Package.Url -OutFile "$(($Directory).FullName)\$($Package.Filename)"
    }
    # Install the dependencies if a dependency file extension is defined
    if($null -ne $DependencyFileextension){
        $Dependencies = $(Get-ChildItem -Filter "*.$($DependencyFileextension)" -File -Path $Directory).FullName
        foreach($Dependency in $Dependencies) {
            Write-Host -ForegroundColor:Green "Installing $($Dependency)"
            Add-AppxProvisionedPackage -Online -PackagePath $Dependency `
            -SkipLicense 1> $null
        }
    }

    # Install the App
    $App = $(Get-ChildItem -Filter "*.$($AppFileextension)" -File -Path $Directory).FullName
    Write-Host -ForegroundColor:Green "Installing $($App)"
    Add-AppxProvisionedPackage -Online -PackagePath $App -SkipLicense 1> $null
}

# Install the DesktopAppInstaller
Invoke-MsStorePackageDownload `
-Packages:$(Get-MicrosoftStoreAssets -PackageFamilyName 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -Ring 'Retail') `
-Directory:"$($PSScriptRoot)\DesktopAppInstaller" `
-AppFileextension:'msixbundle' `
-DependencyFileextension:'appx'

<#
Invoke-MsStorePackageDownload `
-Packages:$(Get-MicrosoftStoreAssets -PackageFamilyName 'Microsoft.WindowsStore_8wekyb3d8bbwe' -Ring 'Retail') `
-Directory:"$($PSScriptRoot)\MicrosoftStore" `
-AppFileextension:'msixbundle' `
-DependencyFileextension:'appx'
#>

Invoke-MsStorePackageDownload `
-Packages:$(Get-MicrosoftStoreAssets -PackageFamilyName 'Microsoft.SysinternalsSuite_8wekyb3d8bbwe' -Ring 'Retail') `
-Directory:"$($PSScriptRoot)\SysinternalsSuite" `
-AppFileextension:'msixbundle'

Write-Host ""