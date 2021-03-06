# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

<#
.Description
    This script deploys the VM, verifies XDP with action DROP/TX.
    This test will configure XDP hook with DROP/Forward ping packets hook for Action testing.
#>

param([object] $AllVmData,
    [object] $CurrentTestData)

$iFaceName = "eth1"

function Main {
    try {
        $noReceiver = $true
        $noSender = $true
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "receiver") {
                $receiverVMData = $vmData
                $noReceiver = $false
            } elseif ($vmData.RoleName -imatch "sender") {
                $noSender = $false
                $senderVMData = $vmData
            }
        }
        if ($noReceiver) {
            Throw "No Receiver VM defined. Aborting Test."
        }
        if ($noSender) {
            Throw "No Sender VM defined. Aborting Test."
        }

        #CONFIGURE VM Details
        Write-LogInfo "RECEIVER VM details :"
        Write-LogInfo "  RoleName : $($receiverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($receiverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($receiverVMData.SSHPort)"
        Write-LogInfo "  Internal IP : $($receiverVMData.InternalIP)"
        Write-LogInfo "SENDER VM details :"
        Write-LogInfo "  RoleName : $($senderVMData.RoleName)"
        Write-LogInfo "  Public IP : $($senderVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($senderVMData.SSHPort)"
        Write-LogInfo "  Internal IP : $($senderVMData.InternalIP)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"

        # Generate constants.sh and write all VM info into it
        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "# Generated by Azure Automation." -Path $constantsFile
        Add-Content -Value "ip=$($receiverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($receiverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "server=$($senderVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "clientSecondIP=$($receiverVMData.SecondInternalIP)" -Path $constantsFile
        Add-Content -Value "serverSecondIP=$($senderVMData.SecondInternalIP)" -Path $constantsFile
        Add-Content -Value "nicName=$iFaceName" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
        }
        switch -Wildcard ($($CurrentTestData.testName)){
            '*DROP*' {Add-Content -Value "ACTION=DROP" -Path $constantsFile}
            '*TX*' {Add-Content -Value "ACTION=TX" -Path $constantsFile}
            '*ABORTED*' {Add-Content -Value "ACTION=ABORTED" -Path $constantsFile}
        }
        Write-LogInfo "constants.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)
        $installXDPCommand = @"
bash ./XDPDumpSetup.sh 2>&1 > ~/xdpConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\StartXDPSetup.sh" $installXDPCommand
        Copy-RemoteFiles -uploadTo $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -files "$constantsFile,$LogDir\StartXDPSetup.sh" `
            -username $user -password $password -upload -runAsSudo

        # Start XDP Setup
        $testJob = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -username $user -password $password -command "bash ./StartXDPSetup.sh" `
            -RunInBackground -runAsSudo
        # Terminate process if ran more than 5 mins
        # TODO: Check max installation time for other distros when added
        $timer = 0
        while ($testJob -and ((Get-Job -Id $testJob).State -eq "Running")) {
            $currentStatus = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "tail -2 ~/xdpConsoleLogs.txt | head -1" -runAsSudo
            Write-LogInfo "Current Test Status: $currentStatus"
            Wait-Time -seconds 20
            $timer += 1
            if ($timer -gt 15) {
                Throw "XDPSetup did not stop after 5 mins. Please check xdpConsoleLogs."
            }
        }

        $currentState = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -username $user -password $password -command "cat state.txt" -runAsSudo

        if ($currentState -imatch "TestCompleted") {
            # Start XDP Action Validation
            Write-LogInfo "Starting XDP validation for Action: $($currentTestData.TestParameters.param)"
            $testJobDrop = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "./XDP-Action.sh > ~/xdpAction.log" `
                -RunInBackground -runAsSudo
            $timer = 0
            while ((Get-Job -Id $testJobDrop).State -eq "Running") {
                $currentStatus = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                    -username $user -password $password -command "tail -2 ~/xdpAction.log | head -1" -runAsSudo
                Write-LogInfo "Current Test Status: $currentStatus"
                Wait-Time -seconds 20
                $timer += 1
                if ($timer -gt 15) {
                    Throw "XDPSetup did not stop after 5 mins. Please check logs."
                }
            }
            $currentState = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "cat state.txt" -runAsSudo
        }

        if ($currentState -imatch "TestCompleted") {
            Write-LogInfo "Test Completed"
            $testResult = "PASS"
        }   elseif ($currentState -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status: $currentStatus."
            $testResult = "ABORTED"
        }   elseif ($currentState -imatch "TestSkipped") {
            Write-LogErr "Test Skipped. Last known status: $currentStatus"
            $testResult = "SKIPPED"
        }   elseif ($currentState -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status: $currentStatus."
            $testResult = "FAIL"
        }   else {
            Write-LogErr "Test execution is not successful, check test logs in VM."
            $testResult = "ABORTED"
        }

        Copy-RemoteFiles -downloadFrom $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -username $user -password $password -download `
            -downloadTo $LogDir -files "*.csv, *.txt, *.log"
        Copy-RemoteFiles -downloadFrom $senderVMData.PublicIP -port $senderVMData.SSHPort `
            -username $user -password $password -download `
            -downloadTo $LogDir -files "*.txt"
    } catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = "ABORTED"
        }
        $resultArr += $testResult
    }
    Write-LogInfo "Test result: $testResult"
    return $testResult
}

Main
