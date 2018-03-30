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
