Set-Location -Path $PSScriptRoot -ErrorAction:Stop
$Script:Repositories = [ordered]@{
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
    'PowerShell' = @{
        'URL' = 'https://github.com/PowerShell/PowerShell'
        'Files' = @(
            '\.msixbundle$'
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
            $Directory = $(Get-ChildItem -Filter $Filter -Directory -Path $PSScriptRoot -Recurse).FullName

            Add-AppxProvisionedPackage -Online -PackagePath $(Get-ChildItem -Force -Recurse -Filter "Microsoft.VCLibs*_x64*.appx" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName

            Add-AppxProvisionedPackage -Online -PackagePath:$(Get-ChildItem -Force -Recurse -Filter "Microsoft.UI.Xaml*_x64*.appx" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName

            # Package Install
            $Filter = "WindowsTerminal"
            $Directory = $(Get-ChildItem -Filter $Filter -Directory -Path $PSScriptRoot).FullName
            Add-AppxProvisionedPackage -Online -PackagePath:$(Get-ChildItem -Force -Recurse -Filter "Microsoft.WindowsTerminal*.msixbundle" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName
        }
        "DesktopAppInstaller" {
            # Package Dependencies
            $Filter = "DesktopAppInstaller"
            $Directory = $(Get-ChildItem -Filter $Filter -Directory -Path $PSScriptRoot).FullName
            # Package Install
            Add-AppxProvisionedPackage -Online -PackagePath:$(Get-ChildItem -Force -Recurse -Filter "Microsoft.DesktopAppInstaller*.msixbundle" -Path:$Directory).FullName -Verbose -LicensePath `
            $(Get-ChildItem -Force -Recurse -Filter "*License*.xml" -Path:$(Get-ChildItem -Filter "$Filter" -Directory).FullName).FullName
        }
        "PowerShell" {
            # Package Install
            $Filter = "PowerShell"
            $Directory = $(Get-ChildItem -Filter $Filter -Directory -Path $PSScriptRoot).FullName
            Add-AppxProvisionedPackage -Online -PackagePath $(Get-ChildItem -Force -Recurse -Filter "PowerShell*.msixbundle" -Path:$Directory).FullName -Verbose `
            -SkipLicense
        }
    }
}