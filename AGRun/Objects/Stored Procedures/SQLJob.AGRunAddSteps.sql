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
