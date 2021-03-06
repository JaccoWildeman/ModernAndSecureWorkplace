<#
.DESCRIPTION
Monitor devices in Intune which are non-compliant and start remediation actions according to your needs.

.EXAMPLE


.NOTES
Author: Thomas Kurth/baseVISION
Date:   02.06.2019

History
    001: First Version


ExitCodes:
    99001: Could not Write to LogFile
    99002: Could not Write to Windows Log
    99003: Could not Set ExitMessageRegistry

#>
[CmdletBinding()]
Param(
)
#region Intune Monitor Variable Definition
########################################################

# Only monitor these types of devices ("mdm","eas","easMdm")
$managementAgents = @("mdm")

# Username to access Intune GraphAPI (MFA should not be enabled)
$Username = "admin@mydomain.onmicrosoft.com" 

# Password of the user
# As SecureString use the following command to create the value "Read-Host -AsSecureString | ConvertFrom-SecureString"
# Important: you have to create the Secure String in powershell command promt which is executed with the same user as the scheduled task will use.
$Password = "01000000d08c9ddf0115d1118c......8f26b1dafbaba8ff78"

#endregion

#region Remediation Actions Variable Definition
########################################################

# Only monitor these types of devices ("Mail","Splunk","Webhook")
$remediationActions = @("Webhook")

## Splunk 
# Sends event to Splunk Rest API
$SplunkToken = "C3ABEA0B-1439-4070-AA51-7216E2DB3105"
$SplunkUrl = "http://SERVER:PORT/services/collector/event"

## Invoke Webrequest
# Sends complete Intune Device Object as JSON by submitting a HTTP POST request to the specified Url
$WebRequestUrl = "https://prod-111.westeurope.logic.azure.com:443/workflows/c5eb5c9b5e414d62bcsdaffe1ff910/triggers/manual/paths/invoke?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=AZEDfMTGi9xLYhm85asdafEz9Muejqfsa93RCiQ56ywk"

## Send Mail
$SmtpServer = "localhost"
$SmtpPort = 21
$SmtpFrom = "sender@mydomain.com"
$SmtpTo = @("support@mydomain.com")
$SmtpSSL = $true
$MailSubject = "New Intune Non-CompliantDevice"

#endregion

#region General Variable Definition
########################################################
$DebugPreference = "Continue"
$VerbosePreference = "Continue"
$ScriptVersion = "001"
$ScriptName = "Intune-Monitor-Compliance"

$LogFilePathFolder     = $env:TEMP
$FallbackScriptPath    = "C:\Windows" # This is only used if the filename could not be resolved(IE running in ISE)

# Log Configuration
$DefaultLogOutputMode  = "Console-LogFile" # "Console-LogFile","Console-WindowsEvent","LogFile-WindowsEvent","Console","LogFile","WindowsEvent","All"
$DefaultLogWindowsEventSource = $ScriptName
$DefaultLogWindowsEventLog = "Intune-Monitor"

#endregion

 
#region Functions
########################################################

function Write-Log {
    <#
    .DESCRIPTION
    Write text to a logfile with the current time.

    .PARAMETER Message
    Specifies the message to log.

    .PARAMETER Type
    Type of Message ("Info","Debug","Warn","Error").

    .PARAMETER OutputMode
    Specifies where the log should be written. Possible values are "Console","LogFile" and "Both".

    .PARAMETER Exception
    You can write an exception object to the log file if there was an exception.

    .EXAMPLE
    Write-Log -Message "Start process XY"

    .NOTES
    This function should be used to log information to console or log file.
    #>
    param(
        [Parameter(Mandatory=$true,Position=1)]
        [String]
        $Message
    ,
        [Parameter(Mandatory=$false)]
        [ValidateSet("Info","Debug","Warn","Error")]
        [String]
        $Type = "Debug"
    ,
        [Parameter(Mandatory=$false)]
        [ValidateSet("Console-LogFile","Console-WindowsEvent","LogFile-WindowsEvent","Console","LogFile","WindowsEvent","All")]
        [String]
        $OutputMode = $DefaultLogOutputMode
    ,
        [Parameter(Mandatory=$false)]
        [Exception]
        $Exception
    )
    
    $DateTimeString = Get-Date -Format "yyyy-MM-dd HH:mm:sszz"
    $Output = ($DateTimeString + "`t" + $Type.ToUpper() + "`t" + $Message)
    if($Exception){
        $ExceptionString =  ("[" + $Exception.GetType().FullName + "] " + $Exception.Message)
        $Output = "$Output - $ExceptionString"
    }

    if ($OutputMode -eq "Console" -OR $OutputMode -eq "Console-LogFile" -OR $OutputMode -eq "Console-WindowsEvent" -OR $OutputMode -eq "All") {
        if($Type -eq "Error"){
            Write-Log -type Error -Message  $output
        } elseif($Type -eq "Warn"){
            Write-Warning $output
        } elseif($Type -eq "Debug"){
            Write-Debug $output
        } else{
            Write-Log $output -Verbose
        }
    }
    
    if ($OutputMode -eq "LogFile" -OR $OutputMode -eq "Console-LogFile" -OR $OutputMode -eq "LogFile-WindowsEvent" -OR $OutputMode -eq "All") {
        try {
            Add-Content $LogFilePath -Value $Output -ErrorAction Stop
        } catch {
            exit 99001
        }
    }

    if ($OutputMode -eq "Console-WindowsEvent" -OR $OutputMode -eq "WindowsEvent" -OR $OutputMode -eq "LogFile-WindowsEvent" -OR $OutputMode -eq "All") {
        try {
            New-EventLog -LogName $DefaultLogWindowsEventLog -Source $DefaultLogWindowsEventSource -ErrorAction SilentlyContinue
            switch ($Type) {
                "Warn" {
                    $EventType = "Warning"
                    break
                }
                "Error" {
                    $EventType = "Error"
                    break
                }
                default {
                    $EventType = "Information"
                }
            }
            Write-EventLog -LogName $DefaultLogWindowsEventLog -Source $DefaultLogWindowsEventSource -EntryType $EventType -EventId 1 -Message $Output -ErrorAction Stop
        } catch {
            exit 99002
        }
    }
}

function New-Folder{
    <#
    .DESCRIPTION
    Creates a Folder if it's not existing.

    .PARAMETER Path
    Specifies the path of the new folder.

    .EXAMPLE
    CreateFolder "c:\temp"

    .NOTES
    This function creates a folder if doesn't exist.
    #>
    param(
        [Parameter(Mandatory=$True,Position=1)]
        [string]$Path
    )
	# Check if the folder Exists

	if (Test-Path $Path) {
		Write-Log "Folder: $Path Already Exists"
	} else {
		New-Item -Path $Path -type directory | Out-Null
		Write-Log "Creating $Path"
	}
}

function Set-RegValue {
    <#
    .DESCRIPTION
    Set registry value and create parent key if it is not existing.

    .PARAMETER Path
    Registry Path

    .PARAMETER Name
    Name of the Value

    .PARAMETER Value
    Value to set

    .PARAMETER Type
    Type = Binary, DWord, ExpandString, MultiString, String or QWord

    #>
    param(
        [Parameter(Mandatory=$True)]
        [string]$Path,
        [Parameter(Mandatory=$True)]
        [string]$Name,
        [Parameter(Mandatory=$True)]
        [AllowEmptyString()]
        [string]$Value,
        [Parameter(Mandatory=$True)]
        [string]$Type
    )
    
    try {
        $ErrorActionPreference = 'Stop' # convert all errors to terminating errors
        Start-Transaction

	   if (Test-Path $Path -erroraction silentlycontinue) {      
 
        } else {
            New-Item -Path $Path -Force
            Write-Log "Registry key $Path created"  
        } 
        $null = New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force
        Write-Log "Registry Value $Path, $Name, $Type, $Value set"
        Complete-Transaction
    } catch {
        Undo-Transaction
        Write-Log "Registry value not set $Path, $Name, $Value, $Type" -Type Error -Exception $_.Exception
    }
}

function Get-AlertLastExecutionTime {
    param(
        [DateTime]$CurrentExecutionTime
    )
    
    $LastExecutionTime = Get-ItemPropertyValue -Path $RegistryKey -Name "LastExecutionTime" -ErrorAction SilentlyContinue
    if($null -eq $LastExecutionTime){
        $LastExecutionTime = $CurrentExecutionTime.AddMinutes(-60)
        Write-Log "Last Execution not found, using current datetime minus 60 minutes ($LastExecutionTime)."
    }
    Write-Log "Use last execution time ($LastExecutionTime)"
    return [DateTime]$LastExecutionTime
}

function Set-AlertLastExecutionTime {
    param(
        [DateTime]$CurrentExecutionTime
    )
    if(-not (Test-Path $RegistryKey)){
        New-Item -Path $RegistryKey -Force
    }
    Set-ItemProperty -Path $RegistryKey -Name "LastExecutionTime" -Value $CurrentExecutionTime -Force -ErrorAction Stop
    Write-Log "Successfully set last execution time ($CurrentExecutionTime)"
}

function Invoke-SendAlertToSplunk {
    param(
        $IntuneDevice
    )  
    try {
        $eventObj = @{
            host = $IntuneDevice.deviceName
            source = "Intune"
            sourcetype = "Compliance"
            event = $IntuneDevice
            }
        $header = @{Authorization = "Splunk $SplunkToken"}
        $event = $eventObj | ConvertTo-Json -Depth 2
        Invoke-RestMethod -Method Post -Uri $SplunkUrl -Headers $header -Body $event
    } catch  {
        Write-Log "Invoke Webhook failed" -Type Error -Exception $_.Exception
    }
 }

function Invoke-SendAlertWebhook {
    param(
        $IntuneDevice
    )  
    try {
        $event = $IntuneDevice | ConvertTo-Json -Depth 2
        Invoke-RestMethod -Method Post -Uri $WebRequestUrl -Body $event -ContentType 'application/json' -ErrorAction Stop
    } catch  {
        Write-Log "Invoke Webhook failed" -Type Error -Exception $_.Exception
    }
}

function Invoke-SendAlertMail {
    param(
        $IntuneDevice
    ) 
    try{
        Send-MailMessage -Body ($IntuneDevice | ft) -SmtpServer $SmtpServer -Port $SmtpPort -Subject $MailSubject -From $SmtpFrom -To $SmtpTo -UseSsl:$SmtpSSL -ErrorAction Stop
    } catch  {
        Write-Log "Send Mail failed" -Type Error -Exception $_.Exception
    }
}

#endregion

#region Dynamic Variables and Parameters
########################################################

# Try get actual ScriptName
try{
    $CurrentFileNameTemp = $MyInvocation.MyCommand.Name
    If($CurrentFileNameTemp -eq $null -or $CurrentFileNameTemp -eq ""){
        $CurrentFileName = "NotExecutedAsScript"
    } else {
        $CurrentFileName = $CurrentFileNameTemp
    }
} catch {
    $CurrentFileName = $LogFilePathScriptName
}
$LogFilePath = "$LogFilePathFolder\{0}_{1}_{2}.log" -f ($ScriptName -replace ".ps1", ''),$ScriptVersion,(Get-Date -uformat %Y%m%d%H%M)
# Try get actual ScriptPath
try{
    try{ 
        $ScriptPathTemp = Split-Path $MyInvocation.MyCommand.Path
    } catch {

    }
    if([String]::IsNullOrWhiteSpace($ScriptPathTemp)){
        $ScriptPathTemp = Split-Path $MyInvocation.InvocationName
    }

    If([String]::IsNullOrWhiteSpace($ScriptPathTemp)){
        $ScriptPath = $FallbackScriptPath
    } else {
        $ScriptPath = $ScriptPathTemp
    }
} catch {
    $ScriptPath = $FallbackScriptPath
}

Write-Log "Using HKLM:\SOFTWARE\Customer\$ScriptName for persistent settings"
$RegistryKey = "HKLM:\SOFTWARE\Customer\$ScriptName"

#endregion

#region Initialization
########################################################

New-Folder $LogFilePathFolder
Write-Log "Start Script $Scriptname"

$CurrentExecutionTime = (Get-Date).ToUniversalTime()
Write-Log "Use current execution time ($CurrentExecutionTime)"

#Get Last Execution 
$LastExecutionTime = Get-AlertLastExecutionTime -CurrentExecutionTime $CurrentExecutionTime

# Get Credentials
Write-Log "Generating PSCred from Password and Username"
$creds = New-Object System.Management.Automation.PSCredential ($Username,($Password | ConvertTo-SecureString))



Write-Log "Connecting to Intune"
$Tenant = Connect-MSGraph -PSCredential $creds

Write-Log "Connected to $($Tenant.TenantId) with $($Tenan.UPN)"


#endregion

#region Main Script
########################################################

Write-Log "Loading non-compliant devices"
$NonCompliantDevices = ,(Get-IntuneManagedDevice -Filter "complianceState eq 'noncompliant'" -Verbose:$false)
Write-Log "Found $($NonCompliantDevices.Count) non-compliant devices"
Write-Log "Filter on ManagementAgent and Timerange($LastexecutionTime - $CurrentExecutionTime)"
$NewAlerts = ,($NonCompliantDevices | Where-Object { $managementAgents -contains $_.managementAgent -and $_.complianceGracePeriodExpirationDateTime -gt $LastexecutionTime -and $_.complianceGracePeriodExpirationDateTime -le $CurrentExecutionTime })
Write-Log "$($NewAlerts.Count) new alerts to raise" 
Write-Log "Invoke the following Actions: $($remediationActions -join ",")" 
ForEach($alert in $NewAlerts){
    Write-Log "Processing Alert for $($alert.deviceName)"
    if($remediationActions -contains "Webhook"){
        Invoke-SendAlertWebhook -IntuneDevice $alert
    }
    if($remediationActions -contains "Splunk"){
        Invoke-SendAlertToSplunk -IntuneDevice $alert
    }
    if($remediationActions -contains "Mail"){
        Invoke-SendAlertMail -IntuneDevice $alert
    }
}


#endregion

#region Finishing
########################################################

Set-AlertLastExecutionTime -CurrentExecutionTime $CurrentExecutionTime

Write-Log "End Script $Scriptname"

#endregion