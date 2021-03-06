[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(Mandatory=$false)]
    [String] $UserName,

    [Parameter(Mandatory=$false)]
    [SecureString] $Password,

    [Parameter(Mandatory=$true)]
    [String] $FileSharePath,

    [Parameter(Mandatory=$true)]
    [String] $DateTimeBefore,    

    [Parameter(Mandatory=$true)]
    [String] $ClusterEndpoint,

    [Parameter(Mandatory=$false)]
    [switch] $Force,

    [Parameter(Mandatory=$false)]
    [String] $PartitionId,

    [Parameter(Mandatory=$false)]
    [String] $ServiceId,

    [Parameter(Mandatory=$false)]
    [String] $ApplicationId,

    [Parameter(Mandatory=$false)]
    [String] $SSLCertificateThumbPrint
)


Add-Type -Namespace Import -Name Win32 -MemberDefinition @' 
    [DllImport("advapi32.dll", SetLastError = true)] 
    public static extern bool LogonUser(string user, string domain, string password, int logonType, int logonProvider, out IntPtr token); 
 
    [DllImport("kernel32.dll", SetLastError = true)] 
    public static extern bool CloseHandle(IntPtr handle); 
'@ 
. .\UtilScript.ps1

Function Get-LogonUserToken 
{
    param([Parameter(Mandatory=$true)][string]$UsernameToLogon, 
    [Parameter(Mandatory=$true)][string]$Domain, 
    [Parameter(Mandatory=$true)][SecureString]$Pass,
    [Parameter(Mandatory=$false)][string]$LogonType = 'NEW_CREDENTIALS',
    [Parameter(Mandatory=$false)][string]$LogonProvider = 'WINNT50'
    ) 
    
    $tokenHandle =  [IntPtr]::Zero
    

    $LogonTypeID = Switch ($LogonType) {
        'BATCH' { 4 }
        'INTERACTIVE' { 2 }
        'NETWORK' { 3 }
        'NETWORK_CLEARTEXT' { 8 }
        'NEW_CREDENTIALS' { 9 }
        'SERVICE' { 5 }
    }

    $LogonProviderID = Switch ($LogonProvider) {
        'DEFAULT' { 0 }
        'WINNT40' { 2 }
        'WINNT50' { 3 }
    }
    $unmanagedString = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Pass)
    $passunenc = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($unmanagedString)
    $returnValue = [Import.Win32]::LogonUser($UsernameToLogon, $Domain, $passunenc, $LogonTypeID, $LogonProviderID, [ref]$tokenHandle) 
 
    #If it fails, throw the verbose with the error code 
    if (!$returnValue) { 
        $errCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error(); 
        Write-Host "Impersonate-User failed a call to LogonUser with error code: $errCode" 
        throw [System.ComponentModel.Win32Exception]$errCode 
        
    } 
    
    return $tokenHandle
}

$filePathList = New-Object System.Collections.ArrayList
$Global:ImpersonatedUser = @{} 

$partitionIdListToWatch = New-Object System.Collections.ArrayList

if($ApplicationId)
{
    Write-Host "Trying to find all the partitions in application : $ApplicationId"
    $partitionIdListToWatch = Get-PartitionIdList -ApplicationId $ApplicationId
}
elseif($ServiceId)
{
    Write-Host "Trying to find all the partitions in Service : $ServiceId"
    $partitionIdListToWatch = Get-PartitionIdList -ServiceId $ServiceId
} 
elseif($PartitionId)
{
    Write-Host "Trying to find all the partitions in Partition : $PartitionId"
    $partitionIdListToWatch.Add($PartitionId) 
}


if($UserName)
{
    $Password = Read-Host -Prompt "Please enter password for the userName: $UserName" -AsSecureString
    $userNameDomainList = $username.Split("\",[StringSplitOptions]'RemoveEmptyEntries')

    if($userNameDomainList.Count -eq 2)
    {
        $userNameToTry = $userNameDomainList[1]
        $domain = $userNameDomainList[0]
    }
    else {
        $userNameToTry = $UserName
        $domain = "."
    }
    
    $userToken = Get-LogonUserToken  -Username $userNameToTry -Domain $domain -Pass $Password
    $Global:ImpersonatedUser.ImpersonationContext = [System.Security.Principal.WindowsIdentity]::Impersonate($userToken) 
         
    # Close the handle to the token. Voided to mask the Boolean return value. 
    [void][Import.Win32]::CloseHandle($userToken) 
    
}

Write-Host "Enumerating the Share : $FileSharePath"

# Here i will perform the impersonation task and make it proper.
Get-ChildItem -Path $FileSharePath -Include *.bkmetadata -Recurse | ForEach-Object {$filePathList.Add($_.FullName) | Out-Null} 
Get-ChildItem -Path $FileSharePath -Include *.zip -Recurse | ForEach-Object {$filePathList.Add($_.FullName) | Out-Null} 

$partitionDict = Get-PartitionDict -pathsList $filePathList
$partitionCountDict = New-Object 'system.collections.generic.dictionary[[String],[Int32]]'
    
foreach($partitionid in $partitionDict.Keys)
{
    $partitionCountDict[$partitionid] = $partitionDict[$partitionid].Count
    if($partitionIdListToWatch.Count -ne 0 -and !$partitionIdListToWatch.Contains($partitionid) )
    {
        continue
    }
    if($SSLCertificateThumbPrint)
    {
        $finalDateTimeObject = Get-FinalDateTimeBefore -DateTimeBefore $DateTimeBefore -Partitionid $partitionid -ClusterEndpoint $ClusterEndpoint -Force $Force -SSLCertificateThumbPrint $SSLCertificateThumbPrint
    }
    else {
        $finalDateTimeObject = Get-FinalDateTimeBefore -DateTimeBefore $DateTimeBefore -Partitionid $partitionid -ClusterEndpoint $ClusterEndpoint -Force $Force        
    }
    if($finalDateTimeObject -eq [DateTime]::MinValue)
    {
        continue
    }
    foreach($filePath in $partitionDict[$partitionid])
    {
        Write-Host "Processing the file: " $filePath
        $fileNameWithExtension = Split-Path $filePath -Leaf
        $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($fileNameWithExtension)
        $extension =  [IO.Path]::GetExtension($fileNameWithExtension)
        if($extension -eq ".zip" -or $extension -eq ".bkmetadata" )
        {
            $dateTimeObject = [DateTime]::ParseExact($fileNameWithoutExtension + "Z","yyyy-MM-dd HH.mm.ssZ",[System.Globalization.DateTimeFormatInfo]::InvariantInfo,[System.Globalization.DateTimeStyles]::None)
            if($dateTimeObject.ToUniversalTime() -lt $finalDateTimeObject.ToUniversalTime())
            {
                Write-Host "Deleting the file: $filePath"
                Remove-Item -Path $filePath
                $partitionCountDict[$partitionid] = $partitionCountDict[$partitionid] -1
                if($partitionCountDict[$partitionid] -lt 0)
                {
                    throw "There is some code bug here."
                }
            }
        }
    }
    Write-Host "Cleanup for the partitionID: $partitionid is complete "
}


Write-Host "Now testing the cleanup."
# Here our test code will work.
$testFilePathList = New-Object System.Collections.ArrayList

Get-ChildItem -Path $FileSharePath -Include *.bkmetadata -Recurse | ForEach-Object {$testFilePathList.Add($_.FullName) | Out-Null} 
Get-ChildItem -Path $FileSharePath -Include *.zip -Recurse | ForEach-Object {$testFilePathList.Add($_.FullName) | Out-Null} 
$newPartitionDict = Get-PartitionDict -pathsList $filePathList

foreach($partitionid in $newPartitionDict.Keys)
{
    if($partitionCountDict.ContainsKey)
    {
        if($partitionCountDict[$partitionid] -gt $newPartitionDict[$partitionid].Count)
        {
            throw "The partition with partitionId : $partitionid has less number of backups than expected."
        }
    }
    Start-BackupDataCorruptionTest -DateTimeBefore $DateTimeBefore  -Partitionid $partitionid -ClusterEndpoint $ClusterEndpoint -SSLCertificateThumbPrint $SSLCertificateThumbPrint
}



if($UserName)
{   
    $ImpersonatedUser.ImpersonationContext.Undo() 
    
    #Clean up the Global variable and the function itself. 
    Remove-Variable ImpersonatedUser -Scope Global 
}

# Now we will go for enumeration
