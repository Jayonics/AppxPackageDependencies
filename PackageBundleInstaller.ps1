$Script:Repositories = @{
    'WindowsTerminal' = @{
        'URL' = 'https://github.com/microsoft/terminal'
        'Files' = @(
            'PreInstallKit\.zip',
            '\.msixbundle$'
        )
    }
    'DesktopAppInstaller' = @{
        'URL' = 'https://github.com/microsoft/winget-cli'
        'Files' = @(
            '\.msixbundle',
            'License.?\.xml',
            'Policies\.zip'
        )
    }
}
$Script:Dependencies = @{
    'WindowsTerminal' = @{
        'Dependencies' = @(
            'Microsoft\.VCLibs',
            'Microsoft\.UI\.Xaml'
        )
    }
}

function CpuArchitectureFilter {
    # This function takes a directory and recursively searches for files that mention a CPU architecture in their name
    # If these files do not match the current CPU architecture, they are removed. Non architecture specific files are kept.
    param(
        [Parameter(Mandatory = $true)]
        [System.String]$Directory
    )
    # Get the CPU architecture of the current system
    $CpuArchitecture = $env:PROCESSOR_ARCHITECTURE
    switch ($CpuArchitecture) {
        'AMD64' {
            $CpuArchitecture = 'x64'
            Write-Host "Translated AMD64 to x64"
        }
        'ARM64' {
            $CpuArchitecture = 'arm64'
            Write-Host "Translated ARM64 to arm64"
        }
        'x86' {
            $CpuArchitecture = 'x86'
            Write-Host "Translated x86 to x86"
        }
        Default {
            Write-Warning -Message "Unknown CPU Architecture: $CpuArchitecture"
            return
        }
    }

    $KnownArchitectures = @(
        'x64',
        'arm(?!64)',
        'arm64',
        'x86'
    )

    # Get all files in the directory
    $Files = Get-ChildItem -Path $Directory -File -Recurse -Force
    foreach($File in $Files) {
        # If the file name matches a known architecture, but not the current architecture, remove it
        if(( Select-String $KnownArchitectures -quiet -InputObject $File.Name ) -and ( Select-String $CpuArchitecture -quiet -notmatch -InputObject $File.Name)) {
            Write-Host "$($File.Name) matches a known architecture which isn't the current architecture: $CpuArchitecture"
            Write-Verbose -Message "Removing $($File.Name)"
            Remove-Item -Path $File.FullName -Force -Verbose
        }
    }
}

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
            -Verbose
            # Parse the response to get the files and URLs
            $Items = @()
            # Create a custom object to store the filename and download URL
            for($i = 0;$i -lt $ApiReponse.Links.Count; $i++) {
                if ($ApiReponse.Links[$i] -like '*.appx*' -or $ApiReponse.Links[$i] -like '*.msix*'){
                    if ($ApiReponse.Links[$i] -like '*_neutral_*' -or $ApiReponse.Links[$i] -like "*_"+$env:PROCESSOR_ARCHITECTURE.Replace("AMD","X").Replace("IA","X")+"_*"){
                        $Asset = [PSCustomObject]@{
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

New-Item -Path "$($PSScriptRoot)\MicrosoftStore" -ItemType Directory -Force -Verbose
foreach($Package in $MSPackages) {
    Write-Verbose -Message "Downloading $($Package.Filename)"
    Invoke-WebRequest -Uri $Package.DownloadUrl -OutFile "$($PSScriptRoot)\MicrosoftStore\$($Package.Filename)" -Verbose
}

$Directory = $(Get-ChildItem -Filter 'MicrosoftStore' -Directory -Path $PSScriptRoot).FullName
$MsixBundle = $(Get-ChildItem -Filter '*.msixbundle' -File -Path $Directory).FullName
$MsStoreDependencies = $(Get-ChildItem -Filter '*.appx' -File -Path $Directory).FullName

# Install the dependencies
foreach($Dependency in $MsStoreDependencies) {
    Write-Verbose -Message "Installing $($Dependency)"
    Add-AppxProvisionedPackage -Online -PackagePath $Dependency -Verbose `
    -SkipLicense
}
Add-AppxProvisionedPackage -Online -PackagePath $MsixBundle -Verbose `
-SkipLicense

function Get-RepositoryAssets {
    param(
        [Parameter(Mandatory = $true)]
        [System.Uri]$RepositoryURL,
        [Parameter(Mandatory = $true)]
        [System.String]$PackageName,
        [Parameter(Mandatory = $true)]
        [System.Collections.ArrayList]$Files
    )
    # For Github repositories, formulate the URI to get the latest release via the API
    if($RepositoryURL.Host -eq 'github.com') {
        [System.Uri]$GithubApiUri = 'https://api.github.com/repos'
        [System.Uri]$RepositoryReleasesApiUrl = [System.Uri]::new("$($GithubApiUri.AbsoluteUri)$($RepositoryURL.LocalPath)/releases/latest")

        # Get the latest release from the repository
        $LatestReleaseAPI = Invoke-RestMethod -Uri $RepositoryReleasesApiUrl -Headers @{ 'Accept' = 'application/vnd.github+json' } -ContentType 'application/vnd.github+json' -Verbose
        $LatestReleaseAssetsAPI = Invoke-RestMethod -Uri $LatestReleaseAPI.assets_url -Method Get -Headers @{ 'Accept' = 'application/vnd.github+json' } -ContentType 'application/vnd.github+json' -Verbose

        # Download the latest release assets
        # If the list of assets is empty, ignore downloading the assets
        if($LatestReleaseAssetsAPI.Count -eq 0) {
            Write-Warning -Message "No assets found for $($RepositoryURL.LocalPath)"
            return
        } else {
            Write-Verbose -Message "Downloading $($LatestReleaseAssetsAPI.Count) assets for $($RepositoryURL.LocalPath)"
            # Make a directory for the repository
            $RepositoryDirectory = New-Item -Path "$($PSScriptRoot)\$($PackageName)" -ItemType Directory -Force -Verbose
            foreach($Asset in $LatestReleaseAssetsAPI) {
                # If the asset name matches one of the files to download, download it
                if (Select-String $Files -InputObject $asset.name -Quiet ) {
                    Write-Host "Matched $($Asset.name)"
                    $AssetName = $Asset.name
                    $AssetURL = $Asset.browser_download_url
                    $AssetLocalPath = Join-Path -Path $RepositoryDirectory -ChildPath $AssetName
                    Write-Verbose -Message "Downloading Asset: $AssetName"
                    Invoke-WebRequest -Uri $AssetURL -OutFile $AssetLocalPath
                }
            }
        }

        # For each ZIP file, extract the contents to the repository directory
        $ZipFiles = Get-ChildItem -Path $RepositoryDirectory -Filter '*.zip' -File -Recurse
        foreach($ZipFile in $ZipFiles) {
            Write-Verbose -Message "Extracting $($ZipFile.Name)"
            # Create a directory for the ZIP file
            $ExtractDir = New-Item -Path "$($RepositoryDirectory)\$($ZipFile.BaseName)" -ItemType Directory -Force -Verbose
            Expand-Archive -Path $ZipFile.FullName -DestinationPath $ExtractDir -Force
            if ($?) {
                Write-Verbose -Message "Successfully extracted $($ZipFile.Name)"
                # Pass the directory to the CPU Architecture Filter
                CpuArchitectureFilter -Directory $ExtractDir.FullName
                # Clean up the ZIP file
                Remove-Item -Path $ZipFile.FullName -Force -Verbose
            } else {
                Write-Warning -Message "Failed to extract $($ZipFile.Name)"
            }
        }
    }
}

foreach($Key in $Script:Repositories.Keys) {
    Get-RepositoryAssets -RepositoryURL $Script:Repositories[$Key].URL -PackageName $Key -Files $Script:Repositories[$Key].Files
    # Begin the installation of the downloaded assets
    # Start by installing the dependencies located in the Win10_PreInstallKit
    # Then install the Windows 10 Terminal AppxPackage
    # Then install DesktopAppInstaller
    switch ($Key) {
        "WindowsTerminal" {
            # Package Dependencies
            $Filter = "Microsoft.WindowsTerminal_*_Windows10*"
            $Directory = $(Get-ChildItem -Filter $Filter -Directory -Path $PSScriptRoot).FullName

            Add-AppxProvisionedPackage -Online -PackagePath $(Get-ChildItem -Force -Recurse -Filter "Microsoft.VCLibs*_x64*.appx" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName

            Add-AppxProvisionedPackage -Online -PackagePath $(Get-ChildItem -Force -Recurse -Filter "Microsoft.UI.Xaml*_x64*.appx" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName

            # Package Install
            $Filter = "WindowsTerminal"
            $Directory = $(Get-ChildItem -Filter $Filter -Directory -Path $PSScriptRoot).FullName
            Add-AppxProvisionedPackage -Online -PackagePath $(Get-ChildItem -Force -Recurse -Filter "Microsoft.WindowsTerminal*.msixbundle" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName
        }
        "DesktopAppInstaller" {
            # Package Dependencies
            $Filter = "DesktopAppInstaller"
            $Directory = $(Get-ChildItem -Filter $Filter -Directory -Path $PSScriptRoot).FullName
            # Package Install
            Add-AppxProvisionedPackage -Online -PackagePath $(Get-ChildItem -Force -Recurse -Filter "Microsoft.DesktopAppInstaller*.msixbundle" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName
        }
    }
}