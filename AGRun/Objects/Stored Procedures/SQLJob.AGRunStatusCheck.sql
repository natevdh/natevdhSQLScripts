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

	Github Link: https://github.com/natevdh/natevdhSQLScripts/AGRun

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
