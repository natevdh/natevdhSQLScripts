New-Item -ItemType file ".\CreateAll.sql" –force

Get-Content .\Objects\Security\Schemas\SQLJob.sql | Add-Content ".\CreateAll.sql"
Get-Content '.\Objects\Types\User-defined Data Types\SQLJob.AGRunJobList.sql' | Add-Content ".\CreateAll.sql"
Get-Content '.\Objects\Tables\SQLJob.AGRunConfig.sql' | Add-Content ".\CreateAll.sql"
Get-Content '.\Objects\Views\SQLJob.AGRunReviewer.sql' | Add-Content ".\CreateAll.sql"
Get-Content '.\Objects\Stored Procedures\*' | Add-Content ".\CreateAll.sql"