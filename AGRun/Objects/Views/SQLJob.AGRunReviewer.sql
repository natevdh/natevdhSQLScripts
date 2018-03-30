SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO


/*
	This View is here to give you a general idea of if the AGRun steps have been added and if they have been configured correctly.

	The AGRunStatus column has 3 types of statuses
		1. No AGRun Steps Setup
		2. AGRun Steps Configured
		3. Error-<Error Description>

	Does Error checks for
		1. If the AGRun steps have been bypassed
		2. If the config is currently missing
		3. If the Step1 and Step2 are not using the same config name 

	Github Link: https://github.com/natevdh/natevdhSQLScripts/tree/master/AGRun
*/
CREATE VIEW [SQLJob].[AGRunReviewer]
AS
SELECT j2.SQLAgentJobName
	,CASE 
		WHEN j2.AGRunConfigName IS NULL 
			THEN 'No AGRun Steps Setup'
		WHEN j2.start_step_id <> 1
			THEN 'Error-Does not start on step 1. AGRun steps bypassed'
		WHEN arc.DriverDatabase IS NULL
			THEN 'Error-AGRun Config Missing'
		WHEN j2.AGRunConfigName <> ISNULL(j2.AGRunConfigNameStep2,'<MISSING>')
			THEN 'Error-Steps for AGRun are not using same config'
		ELSE 'AGRun Steps Configured'
		END AS AGRunStatus
	,j2.AGRunConfigName
	,arc.DriverDatabase AS AGRunDriverDatabase
	,arc.RunIfNotInAG
	,j2.RealStartStepID
	,jsStart.step_name AS RealStartStepName
	,jsStart.subsystem AS RealStartSubSystem
	,jsStart.database_name AS RealStartDatabaseName
	,jsStart.command AS RealStartCommand
FROM (
	SELECT 
		j.job_id
		,j.name AS SQLAgentJobName
		, CASE 
			WHEN js1.step_name = 'AGRun Status Check Step 1'
				THEN SUBSTRING(
						js1.command
						,CHARINDEX('@AGRunConfigName = ''',js1.command)+20
						,CHARINDEX('''',js1.command,
									CHARINDEX('@AGRunConfigName = ''',js1.command)+20
									) - CHARINDEX('@AGRunConfigName = ''',js1.command)-20
						)
			END AS AGRunConfigName
		, CASE 
			WHEN js2.step_name = 'AGRun Status Check Step 2'
				THEN SUBSTRING(
						js2.command
						,CHARINDEX('@AGRunConfigName = ''',js2.command)+20
						,CHARINDEX('''',js2.command,
									CHARINDEX('@AGRunConfigName = ''',js2.command)+20
									) - CHARINDEX('@AGRunConfigName = ''',js2.command)-20
						)
			END AS AGRunConfigNameStep2
		,CASE 
			WHEN js1.step_name = 'AGRun Status Check Step 1' 
				THEN js1.on_success_step_id
			ELSE j.start_step_id
			END AS RealStartStepID
		,j.start_step_id
	FROM msdb.dbo.sysjobs j
	LEFT JOIN msdb.dbo.sysjobsteps js1 
		ON js1.job_id = j.job_id 
		AND js1.step_id = 1
	LEFT JOIN msdb.dbo.sysjobsteps js2 
		ON js2.job_id = j.job_id 
		AND js2.step_id = 2
) j2
LEFT JOIN msdb.dbo.sysjobsteps jsStart 
	ON jsStart.job_id = j2.job_id 
	AND jsStart.step_id = j2.RealStartStepID	
LEFT JOIN SQLJob.AGRunConfig arc ON arc.AGRunConfigName = j2.AGRunConfigName
GO
