CREATE SCHEMA [SQLJob]
AUTHORIZATION [dbo]
GO
CREATE TYPE [SQLJob].[AGRunJobList] AS TABLE
(
[SQLAgentJobName] [sys].[sysname] NOT NULL,
[AGRunConfigName] [varchar] (100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
PRIMARY KEY CLUSTERED  ([SQLAgentJobName])
)
GO
CREATE TABLE [SQLJob].[AGRunConfig]
(
[AGRunConfigName] [varchar] (100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
[DriverDatabase] [sys].[sysname] NOT NULL,
[RunIfNotInAG] [bit] NOT NULL
) ON [PRIMARY]
GO
ALTER TABLE [SQLJob].[AGRunConfig] ADD CONSTRAINT [PKC_AGRunConfig_ConfigName] PRIMARY KEY CLUSTERED  ([AGRunConfigName]) ON [PRIMARY]
GO
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
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO

/*
	Description:
		This Adds the AG Run Steps to the list of SQLAgentJobs provided.
			If the SQL Agent Jobs passed already has the AGRun steps it will drop and readd them.
			This is to allow you to change the Config name easily and allow for re-running of the scripts without error

		IsDebug - (Optional Parameter) 
			-if NULL or 0 is passed it will add steps
			-if 1 is passed it will show a before and after of the job steps and then roll back		

	Example:
		
		DECLARE @SQLAgentJobs SQLJob.AGRunJobList

		INSERT INTO @SQLAgentJobs (
			SQLAgentJobName
			, AGRunConfigName
		)
		VALUES 
			( 'AGDemo - Simple Job 1' , 'AGDemo' )

		EXECUTE SQLJob.AGRunAddSteps
			@SQLAgentJobs = @SQLAgentJobs -- AGRunJobList
			, @IsDebug = 1 -- bit

	Github Link: https://github.com/natevdh/natevdhSQLScripts/tree/master/AGRun
*/
CREATE PROCEDURE [SQLJob].[AGRunAddSteps] (
	@SQLAgentJobs SQLJob.AGRunJobList READONLY
	,@IsDebug BIT = 0 
)
AS
--Declare @SQLAgentJobs SQLJob.AGRunJobList READONLY = 
--	,@IsDebug BIT = 1 
BEGIN
	SET NOCOUNT ON;
	BEGIN TRY
		BEGIN TRANSACTION

		BEGIN --Declare Variables/TableVariables/TempTables
			DECLARE  @ErrorText NVARCHAR(MAX)
				,@DatabaseWhereAGRunLives sysname

				--Outer Loop
				,@CurrentJobLoopID INT
				,@MaxJobLoopID INT
				
				,@job_id UNIQUEIDENTIFIER
				,@SQLAgentJobName sysname
				,@AGRunConfigName VARCHAR(100)
				,@RequiresDrop BIT

				--Inner Loop
				,@CurrentJobStepID INT
				,@MaxJobStepID INT
				,@StartOnStep INT
				,@Step1Code NVARCHAR(MAX)
				,@Step1Name sysname
				,@Step2Code NVARCHAR(MAX)
				,@Step2Name sysname

				--JobSteps
				,@step_id INT
				,@step_name SYSNAME
				,@subsystem NVARCHAR(40)
				,@command NVARCHAR(max)
				,@flags INT
				,@additional_parameters NVARCHAR(max)
				,@cmdexec_success_code INT
				,@on_success_action TINYINT
				,@on_success_step_id INT
				,@on_fail_action TINYINT
				,@on_fail_step_id INT
				,@server SYSNAME
				,@database_name SYSNAME
				,@database_user_name SYSNAME
				,@retry_attempts INT
				,@retry_interval INT
				,@os_run_priority INT
				,@output_file_name NVARCHAR(200)
				,@proxy_id INT

			--IF OBJECT_ID('tempdb..#JobList') IS NOT NULL
			--BEGIN
			--	DROP TABLE #JobList
			--END

			--IF OBJECT_ID('tempdb..#JobSteps') IS NOT NULL
			--BEGIN
			--	DROP TABLE #JobSteps
			--END

			CREATE TABLE #JobList
			(
				JobLoopID INT NOT NULL IDENTITY PRIMARY KEY
				,job_id UNIQUEIDENTIFIER NOT NULL
				,SQLAgentJobName sysname NOT NULL
				,AGRunConfigName VARCHAR(100) NOT NULL
				,RequiresDrop BIT NOT NULL
			);


			CREATE TABLE #JobSteps (
				[step_id] [INT] NOT NULL PRIMARY KEY
				,[step_name] [sysname] NOT NULL
				,[subsystem] [NVARCHAR](40) NOT NULL
				,[command] [NVARCHAR](MAX) NULL
				,[flags] [INT] NOT NULL
				,[additional_parameters] [NVARCHAR](MAX) NULL
				,[cmdexec_success_code] [INT] NOT NULL
				,[on_success_action] [TINYINT] NOT NULL
				,[on_success_step_id] [INT] NOT NULL
				,[on_fail_action] [TINYINT] NOT NULL
				,[on_fail_step_id] [INT] NOT NULL
				,[server] [sysname] NULL
				,[database_name] [sysname] NULL
				,[database_user_name] [sysname] NULL
				,[retry_attempts] [INT] NOT NULL
				,[retry_interval] [INT] NOT NULL
				,[os_run_priority] [INT] NOT NULL
				,[output_file_name] [NVARCHAR](200) NULL
				,[proxy_id] [INT] NULL
				);
		END

		BEGIN --Parameter Verification / Utilization
			IF NOT EXISTS (
				SELECT 1
				FROM @SQLAgentJobs saj
			)
			BEGIN
				SELECT @ErrorText = 'AGRunAddSteps: You need to pass at least 1 SQL Agent Job Name'
				;THROW 50000,@ErrorText,1;
			END

			IF EXISTS (
				SELECT 1
				FROM @SQLAgentJobs saj
				WHERE NOT EXISTS (
					SELECT 1
					FROM msdb.dbo.sysjobs j
					WHERE j.name = saj.SQLAgentJobName
				)
			)
			BEGIN
				SELECT @ErrorText =  'AGRunAddSteps: Could not find one of the SQL Agent Jobs that was passed in. See Result Set for more info'

				SELECT saj.SQLAgentJobName AS MissingSQLAgentJob
				FROM @SQLAgentJobs saj
				WHERE NOT EXISTS (
					SELECT 1
					FROM msdb.dbo.sysjobs j
					WHERE j.name = saj.SQLAgentJobName
				)

				;THROW 50000,@ErrorText,1;
			END
			
			IF EXISTS (
				SELECT 1
				FROM @SQLAgentJobs saj
				JOIN msdb.dbo.sysjobs j ON j.name = saj.SQLAgentJobName
				WHERE NOT EXISTS (
					SELECT 1
					FROM msdb.dbo.sysjobsteps js
					WHERE js.job_id = j.job_id
				)
			)
			BEGIN
				SELECT @ErrorText = 'AGRunAddSteps: One of the SQL Agent Jobs that was passed in does not have any steps. This requires at least 1. See Result Set for more info'

				SELECT saj.SQLAgentJobName AS SQLAgentJobMissingSteps
				FROM @SQLAgentJobs saj
				JOIN msdb.dbo.sysjobs j ON j.name = saj.SQLAgentJobName
				WHERE NOT EXISTS (
					SELECT 1
					FROM msdb.dbo.sysjobsteps js
					WHERE js.job_id = j.job_id
				)

				;THROW 50000,@ErrorText,1;
			END

			IF EXISTS (
				SELECT 1
				FROM @SQLAgentJobs saj
				WHERE NOT EXISTS (
					SELECT 1
					FROM SQLJob.AGRunConfig arc
					WHERE arc.AGRunConfigName = saj.AGRunConfigName
				)
			)
			BEGIN
				SELECT @ErrorText = 'AGRunAddSteps: Could not find one of the AGRunConfigNames that was passed in. See Result Set for more info'

				SELECT saj.AGRunConfigName AS MissingAGRunConfigName
				FROM @SQLAgentJobs saj
				WHERE NOT EXISTS (
					SELECT 1
					FROM SQLJob.AGRunConfig arc
					WHERE arc.AGRunConfigName = saj.AGRunConfigName
				)

				;THROW 50000,@ErrorText,1;
			END

			IF @IsDebug IS NULL
			BEGIN
				SELECT @IsDebug = CONVERT(BIT,0)
			END
		END

		IF @IsDebug = 1
		BEGIN
			--Begin State
			SELECT 
				saj.SQLAgentJobName
				, j.start_step_id
				, js.job_id
				, js.step_id
				, js.step_name
				, js.subsystem
				, js.command
				, js.flags
				, js.additional_parameters
				, js.cmdexec_success_code
				, js.on_success_action
				, js.on_success_step_id
				, js.on_fail_action
				, js.on_fail_step_id
				, js.server
				, js.database_name
				, js.database_user_name
				, js.retry_attempts
				, js.retry_interval
				, js.os_run_priority
				, js.output_file_name
				, js.last_run_outcome
				, js.last_run_duration
				, js.last_run_retries
				, js.last_run_date
				, js.last_run_time
				, js.proxy_id
				, js.step_uid
			FROM @SQLAgentJobs saj
			JOIN msdb.dbo.sysjobs j ON j.name = saj.SQLAgentJobName
			LEFT JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
			ORDER BY saj.SQLAgentJobName
				,js.step_id
		END

		BEGIN --Do some needed setup
			SELECT @DatabaseWhereAGRunLives = DB_NAME()
				,@Step1Name = 'AGRun Status Check Step 1'
				,@Step2Name = 'AGRun Status Check Step 2'

			INSERT INTO #JobList (
				job_id
				,SQLAgentJobName
				, AGRunConfigName
				, RequiresDrop
			)
			SELECT j.job_id
				,saj.SQLAgentJobName
				,saj.AGRunConfigName
				,CASE WHEN js.step_name = @Step1Name THEN 1 ELSE 0 END AS RequiresDrop
			FROM @SQLAgentJobs saj
			JOIN msdb.dbo.sysjobs j ON j.name = saj.SQLAgentJobName
			JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id AND js.step_id = 1

			SELECT @CurrentJobLoopID = 1
				,@MaxJobLoopID = @@ROWCOUNT

		END

		BEGIN --Loop through each job adding the needed steps
			
			WHILE @CurrentJobLoopID <= @MaxJobLoopID
			BEGIN
				SELECT @job_id = jl.job_id
					,@SQLAgentJobName = jl.SQLAgentJobName
					,@AGRunConfigName = jl.AGRunConfigName
					,@RequiresDrop = jl.RequiresDrop
				FROM #JobList jl
				WHERE jl.JobLoopID = @CurrentJobLoopID

				IF @RequiresDrop = CONVERT(BIT,1)
				BEGIN
					/*
						If the job steps already exist we will drop and re-add them
						This ensures that they are setup correctly and that they are 
						pointed at the config that is most recently created. 
					*/
					EXEC [SQLJob].[AGRunDropSteps] @SQLAgentJobName = @SQLAgentJobName		
				END

				BEGIN --Get info about current state of job
					--Calculate which job step to go to after the new step 1 is added
					SELECT @StartOnStep = j.start_step_id
					FROM msdb.dbo.sysjobs j
					WHERE j.job_id = @job_id

					--Save off current steps
					INSERT INTO #JobSteps (
						[step_id]
						,[step_name]
						,[subsystem]
						,[command]
						,[flags]
						,[additional_parameters]
						,[cmdexec_success_code]
						,[on_success_action]
						,[on_success_step_id]
						,[on_fail_action]
						,[on_fail_step_id]
						,[server]
						,[database_name]
						,[database_user_name]
						,[retry_attempts]
						,[retry_interval]
						,[os_run_priority]
						,[output_file_name]
						,[proxy_id]
						)
					SELECT 
						js.step_id
					  , js.step_name
					  , js.subsystem
					  , js.command
					  , js.flags
					  , js.additional_parameters
					  , js.cmdexec_success_code
					  , js.on_success_action
					  , js.on_success_step_id
					  , js.on_fail_action
					  , js.on_fail_step_id
					  , js.server
					  , js.database_name
					  , js.database_user_name
					  , js.retry_attempts
					  , js.retry_interval
					  , js.os_run_priority
					  , js.output_file_name
					  , js.proxy_id
					FROM msdb.dbo.sysjobsteps js
					WHERE js.job_id = @job_id

					SELECT 
						@CurrentJobStepID = MAX(js.step_id)
						,@MaxJobStepID = MAX(js.step_id)
					FROM #JobSteps js
				END

				BEGIN --Drop all current steps
					/*
						Drops all of the current steps.
						Dont worry they will be added back
					*/
					WHILE @CurrentJobStepID > 0
					BEGIN
						EXEC msdb.dbo.sp_delete_jobstep
							@job_id = @job_id 
							, @step_id = @CurrentJobStepID 

						SELECT @CurrentJobStepID = @CurrentJobStepID -1
					END
					
				END
				
				BEGIN
					EXEC msdb.dbo.sp_update_job
						@job_id = @job_id -- uniqueidentifier
						, @start_step_id = 1 -- int
					
				END

				BEGIN --Add AGRun Steps

					--Puts it on the correct starting step because not all jobs will have been set to start on step 1
					SELECT @StartOnStep = @StartOnStep + 2

					SELECT @Step1Code = 'EXECUTE [SQLJob].[AGRunStatusCheck] @JobStepID = 1 , @AGRunConfigName = '''+@AGRunConfigName+'''	'
						,@Step2Code = 'EXECUTE [SQLJob].[AGRunStatusCheck] @JobStepID = 2 , @AGRunConfigName = '''+@AGRunConfigName+'''	'


					EXEC msdb.dbo.sp_add_jobstep @job_id = @job_id
						,@step_name = @Step1Name
						,@step_id = 1
						,@cmdexec_success_code = 0
						,@on_success_action = 4
						--This is to ensure that it goes to the proper step after the first one executes
						,@on_success_step_id = @StartOnStep
						,@on_fail_action = 4
						,@on_fail_step_id = 2
						,@retry_attempts = 0
						,@retry_interval = 0
						,@os_run_priority = 0
						,@subsystem = N'TSQL'
						,@command = @Step1Code
						,@database_name = @DatabaseWhereAGRunLives
						,@flags = 0

					EXEC msdb.dbo.sp_add_jobstep @job_id = @job_id
						,@step_name = @Step2Name
						,@step_id = 2
						,@cmdexec_success_code = 0
						,@on_success_action = 1
						,@on_success_step_id = 0
						,@on_fail_action = 2
						,@on_fail_step_id = 0
						,@retry_attempts = 0
						,@retry_interval = 0
						,@os_run_priority = 0
						,@subsystem = N'TSQL'
						,@command = @Step2Code
						,@database_name = @DatabaseWhereAGRunLives
						,@flags = 0
				END

				BEGIN --Add the orignal steps back in
					SELECT @CurrentJobStepID = 1
						--Max was set above

					WHILE @CurrentJobStepID <= @MaxJobStepID
					BEGIN

						SELECT @step_id = js.step_id + 2
							,@step_name = js.step_name
							,@subsystem = js.subsystem
							,@command = js.command
							,@cmdexec_success_code = js.cmdexec_success_code
							,@additional_parameters = js.additional_parameters
							,@on_success_action = js.on_success_action
							,@on_success_step_id = CASE 
								WHEN js.on_success_step_id = 0
									THEN 0
								ELSE js.on_success_step_id + 2
								END
							,@on_fail_action = js.on_fail_action
							,@on_fail_step_id = CASE 
								WHEN js.on_fail_step_id = 0
									THEN 0
								ELSE js.on_fail_step_id + 2
								END
							,@server = js.SERVER
							,@database_name = js.database_name
							,@database_user_name = js.database_user_name
							,@retry_attempts = js.retry_attempts
							,@retry_interval = js.retry_interval
							,@os_run_priority = js.os_run_priority
							,@output_file_name = js.output_file_name
							,@flags = js.flags
							,@proxy_id = js.proxy_id
						FROM #JobSteps js
						WHERE js.step_id = @CurrentJobStepID


						EXEC msdb.dbo.sp_add_jobstep @job_id = @job_id
							,@step_id = @step_id
							,@step_name = @step_name
							,@subsystem = @subsystem
							,@command = @command
							,@additional_parameters = @additional_parameters
							,@cmdexec_success_code = @cmdexec_success_code
							,@on_success_action = @on_success_action
							,@on_success_step_id = @on_success_step_id
							,@on_fail_action = @on_fail_action
							,@on_fail_step_id = @on_fail_step_id
							,@server = @server
							,@database_name = @database_name
							,@database_user_name = @database_user_name
							,@retry_attempts = @retry_attempts
							,@retry_interval = @retry_interval
							,@os_run_priority = @os_run_priority
							,@output_file_name = @output_file_name
							,@flags = @flags
							,@proxy_id = @proxy_id

						SELECT @CurrentJobStepID = @CurrentJobStepID + 1
					END
				END

				SELECT @CurrentJobLoopID = @CurrentJobLoopID + 1
			END
		END
		
		
		IF @IsDebug = 1
		BEGIN
			--After State
			SELECT 
				saj.SQLAgentJobName
				, j.start_step_id
				, js.job_id
				, js.step_id
				, js.step_name
				, js.subsystem
				, js.command
				, js.flags
				, js.additional_parameters
				, js.cmdexec_success_code
				, js.on_success_action
				, js.on_success_step_id
				, js.on_fail_action
				, js.on_fail_step_id
				, js.server
				, js.database_name
				, js.database_user_name
				, js.retry_attempts
				, js.retry_interval
				, js.os_run_priority
				, js.output_file_name
				, js.last_run_outcome
				, js.last_run_duration
				, js.last_run_retries
				, js.last_run_date
				, js.last_run_time
				, js.proxy_id
				, js.step_uid
			FROM @SQLAgentJobs saj
			JOIN msdb.dbo.sysjobs j ON j.name = saj.SQLAgentJobName
			LEFT JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
			ORDER BY saj.SQLAgentJobName
				,js.step_id

			ROLLBACK TRANSACTION
		END
		ELSE
		BEGIN
			COMMIT TRANSACTION
		END
		
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0
		BEGIN
			ROLLBACK TRANSACTION;
		END;
		THROW;
	END CATCH
END

GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO

/*
	Description:
		This removes the job steps if they exist and sets the start step to the appropriate step. 
		It was built presuming that you would not want to do this in bulk so it only takes in 1 job name at a time.

	Example:
		EXEC SQLJob.AGRunDropSteps 
			@SQLAgentJobName = 'AGDemo - Simple Job 1'

	Github Link: https://github.com/natevdh/natevdhSQLScripts/tree/master/AGRun
*/
CREATE PROCEDURE [SQLJob].[AGRunDropSteps] (
	@SQLAgentJobName sysname
)
AS
BEGIN
	SET NOCOUNT ON;
	BEGIN TRY
		BEGIN TRANSACTION

		BEGIN --Declare Variables/TableVariables/TempTables
			DECLARE  @ErrorText NVARCHAR(MAX)
				,@Step1Name sysname
				,@Step2Name sysname
				,@StartOnStep INT

			SELECT @Step1Name = 'AGRun Status Check Step 1'
				,@Step2Name = 'AGRun Status Check Step 2'


		END

		BEGIN --Parameter Verification / Utilization
			IF NOT EXISTS (
				SELECT 1
				FROM msdb.dbo.sysjobs j
				WHERE j.name = @SQLAgentJobName
			)
			BEGIN
				SELECT @ErrorText = 'AGRunDropSteps: @SQLAgentJobName not found'
				;THROW 50000,@ErrorText,1;
			END
			
			IF NOT EXISTS (
				SELECT 1
				FROM msdb.dbo.sysjobs j
				JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
				WHERE j.name = @SQLAgentJobName
				AND js.step_id = 1
				AND js.step_name = @Step1Name
			)
			BEGIN
				SELECT @ErrorText = 'AGRunDropSteps: Step 1 Name is not what is expected'
				;THROW 50000,@ErrorText,1;
			END

			IF NOT EXISTS (
				SELECT 1
				FROM msdb.dbo.sysjobs j
				JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
				WHERE j.name = @SQLAgentJobName
				AND js.step_id = 2
				AND js.step_name = @Step2Name
			)
			BEGIN
				SELECT @ErrorText = 'AGRunDropSteps: Step 2 Name is not what is expected'
				;THROW 50000,@ErrorText,1;
			END
			
			IF EXISTS (
				SELECT 1
				FROM msdb.dbo.sysjobs j 
				WHERE j.name = @SQLAgentJobName
				AND j.start_step_id <> 1
			)
			BEGIN
				SELECT @ErrorText = 'AGRunDropSteps: The SQL Agent Job with AGRun steps has been modified to not start on step 1. In order for the DROP Steps process to function correctly this is required. Please put the start step back to step 1'

				;THROW 50000,@ErrorText,1;
			END

		END

		BEGIN --Get the appropriate Start Step
			SELECT @StartOnStep = js.on_success_step_id - 2
			FROM msdb.dbo.sysjobs j
			JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
			WHERE j.name = @SQLAgentJobName
			AND js.step_id = 1
		END

		BEGIN --Delete the 2 steps
			EXEC msdb.dbo.sp_delete_jobstep
				@job_name = @SQLAgentJobName
				, @step_id = 2
			EXEC msdb.dbo.sp_delete_jobstep
				@job_name = @SQLAgentJobName 
				, @step_id = 1
		END

		BEGIN
			EXEC msdb.dbo.sp_update_job
				@job_name = @SQLAgentJobName
				, @start_step_id = @StartOnStep 
		END
			
		--ROLLBACK TRANSACTION
		COMMIT TRANSACTION
		
	END TRY
	BEGIN CATCH
		IF @@TRANCOUNT > 0
		BEGIN
			ROLLBACK TRANSACTION;
		END;
		THROW;
	END CATCH
END

GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO

/*
	Description:
		Does checks for if a job should run or not when being configured for an availibity group
		@JobStepID - Only 1 or 2. 
			Step 2 only does config verification. 
			Step 1 Does the config verification and runs the check to see if it should run or not
		@ConfigName - Name of the config value in AG.DRJobConfig

	Github Link: https://github.com/natevdh/natevdhSQLScripts/tree/master/AGRun

*/
CREATE PROCEDURE [SQLJob].[AGRunStatusCheck] (
	@JobStepID TINYINT
	,@AGRunConfigName VARCHAR(100)
)
AS
BEGIN
	SET NOCOUNT ON;
	BEGIN TRY
	
		BEGIN --Declare Variables/TableVariables/TempTables
			DECLARE  @ErrorText NVARCHAR(MAX)
				,@DriverDatabase sysname
				,@RunIfNotInAG BIT

				,@StatusInAG NVARCHAR(60)
		END

		BEGIN --Parameter Verification / Utilization
			IF @JobStepID NOT IN (1,2)
			BEGIN
				SELECT @ErrorText = '@JobStepID must be either 1 or 2'
				;THROW 50000,@ErrorText,1;
			END
		END

		IF @JobStepID IN (1,2)
		BEGIN --Config Verification
			IF NOT EXISTS (
				SELECT 1
				FROM SQLJob.AGRunConfig djc
				WHERE djc.AGRunConfigName = @AGRunConfigName
			)
			BEGIN
				SELECT @ErrorText = 'Could not find a config matching @AGRunConfigName'
				;THROW 50000,@ErrorText,1;
			END

			SELECT @DriverDatabase = djc.DriverDatabase
				,@RunIfNotInAG = djc.RunIfNotInAG
			FROM SQLJob.AGRunConfig djc
			WHERE djc.AGRunConfigName = @AGRunConfigName

			IF NOT EXISTS (
				SELECT 1
				FROM sys.databases d
				WHERE d.name = @DriverDatabase
			)
			BEGIN
				SELECT @ErrorText = '@DriverDatabase Not Found on server'
				;THROW 50000,@ErrorText,1;
			END
		END

		IF @JobStepID = 1
		BEGIN
			SELECT @StatusInAG = ars.role_desc
			FROM sys.dm_hadr_availability_replica_states ars
			INNER JOIN sys.dm_hadr_database_replica_states drs 
				ON ars.replica_id = drs.replica_id
				AND ars.group_id = drs.group_id
			WHERE drs.is_local = 1 
			AND drs.database_id = DB_ID(@DriverDatabase)

			IF NOT (
				@StatusInAG = 'PRIMARY'
				OR (
					@StatusInAG IS NULL --It will be null if it is not in the AG at all
					AND @RunIfNotInAG = CONVERT(BIT,1)
				)
			)
			BEGIN
				SELECT @ErrorText = '@Job should not run here currently. Erroring out of Step 1'
				;THROW 50000,@ErrorText,1;
			END
		END
		
	END TRY
	BEGIN CATCH
		;THROW;
	END CATCH
END

GO
