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
            # Form the URI to get the URL from the rg-adguard API
            $ApiReponse = Invoke-WebRequest `
            -Method:Post `
            -Uri 'https://store.rg-adguard.net/api/GetFiles' `
            -Body "type=$($PSCmdlet.ParameterSetName)&url=$PackageFamilyName&ring=$Ring" `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -Verbose

            # Parse the response to get the files and URLs
            $Items = @()
            # Create a custom object to store the filename and download URL
            for($i = 0;$i -lt $ApiReponse.Links.Count; $i++) {
                if ($ApiReponse.Links[$i] -like '*.appx*' -or $ApiReponse.Links[$i] -like '*.msix*'){
                    if ($ApiReponse.Links[$i] -like '*_neutral_*' -or $ApiReponse.Links[$i] -like "*_"+$env:PROCESSOR_ARCHITECTURE.Replace("AMD","X").Replace("IA","X")+"_*"){
                        $Asset = [ordered]@{
                            'Filename' = ($ApiReponse.Links[$i] | Select-String -Pattern '(?<=noreferrer">).+(?=</a>)').Matches.Value
                            'DownloadUrl' = ($ApiReponse.Links[$i] | Select-String -Pattern '(?<=a href=").+(?=" r)').Matches.Value
                        }
                        $Items += $Asset
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

$MSPackages = Get-MicrosoftStoreAssets -PackageFamilyName 'Microsoft.WindowsStore_8wekyb3d8bbwe' -Ring 'RP'

$MsStoreDownloadPath = New-Item -Path "$($PSScriptRoot)\MicrosoftStore" -ItemType Directory -Force -Verbose
$MSPackages | % {
    Write-Verbose -Message "Downloading $($_.FileName)"
    Invoke-WebRequest -Uri:$_.DownloadUrl -OutFile "$(($MsStoreDownloadPath).FullName)\$($Package.Filename)" -Verbose
}

$Directory = $(Get-ChildItem -Filter 'MicrosoftStore' -Directory -Path $PSScriptRoot).FullName
$MsixBundle = $(Get-ChildItem -Filter '*.msixbundle' -File -Path $Directory).FullName
$MsStoreDependencies = $(Get-ChildItem -Filter '*.appx' -File -Path $Directory).FullName
#$LicenseFile = Get-Item -Path:".\WindowsTerminal\Microsoft.WindowsTerminal_1.17.11461.0_8wekyb3d8bbwe.msixbundle_Windows10_PreinstallKit\1ff951bd438b4b28b40cb1599e7c9f72_License1.xml" -ErrorAction:Throw


# Install the dependencies
foreach($Dependency in $MsStoreDependencies) {
    Write-Verbose -Message "Installing $($Dependency)"
    Add-AppxProvisionedPackage -Online -PackagePath $Dependency -Verbose `
    -SkipLicense
}
Add-AppxProvisionedPackage -Online -PackagePath $MsixBundle -Verbose `
-SkipLicense


# Download the Sysinternals Suite
$SysinternalsFolder = New-Item -Path "$($PSScriptRoot)\SysinternalsSuite" -ItemType Directory -Force -Verbose
Get-MicrosoftStoreAssets -PackageFamilyName 'Microsoft.SysinternalsSuite_8wekyb3d8bbwe' -Ring 'RP' | % {
    Write-Verbose -Message "Downloading $($_.FileName)"
    Invoke-WebRequest -Uri:$_.DownloadUrl -OutFile "$(($SysinternalsFolder).FullName)\$($Package.Filename)" -Verbose
}
# Install the Sysinternals Suite
$Package = Get-ChildItem -Filter '*.appx*' -File -Path $SysinternalsFolder
Write-Verbose -Message "Installing $($Package.FullName)"
Add-AppxProvisionedPackage -Online -PackagePath $Package.FullName -Verbose `
-SkipLicense

Write-Host ""