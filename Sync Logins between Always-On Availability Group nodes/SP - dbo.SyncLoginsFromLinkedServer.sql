SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/*
	Description:
		The job of this proc to to sync logins from a Primary server in an availibility group to the secondary server. It does this utilizing a linked server.

		It will error out if the Linked server is not the primary in the AG or if the linked server is not working

		It will ignore a list of Logins that would adversley be affected if they were dropped.
			For specific rules look at the details in code

		If SIDs dont match for SQL Logins it will recreate those users

		It will also sync Server level Permissions and Roles from the Primary to the Secondary
			NOTE: there are no permissions being adjusted inside of databases
*/
CREATE PROCEDURE [dbo].[SyncLoginsFromLinkedServer] (
	@LinkedServerName NVARCHAR(128)
	,@CommitChanges BIT
	/*
		3 Debug levels
		0 - No Debug Output
		1 - Only the Work To Do table
		2 - Lots of verbose data
	*/
	, @DebugLevel INT
)
AS
--Declare @LinkedServerName NVARCHAR(128) = 'NHASQL516'
--	, @CommitChanges BIT = 1
--	, @DebugLevel INT = 0
BEGIN
	SET NOCOUNT ON;
	BEGIN TRY

		BEGIN --Declare Variables/TableVariables/TempTables
			DECLARE  @ErrorText NVARCHAR(MAX)
				,@SQLToRun NVARCHAR(MAX)
				,@SQLToRunParameters NVARCHAR(MAX)
				,@CurrentWorkToDoID INT
				,@MaxWorkToDoID INT

			IF OBJECT_ID('tempdb..#BaseLoginInfo') IS NOT NULL
			BEGIN
				DROP TABLE #BaseLoginInfo
			END

			CREATE TABLE #BaseLoginInfo
			(
				IsFromLinkedServer BIT NOT NULL
				,sid VARBINARY(85) NOT NULL
				,LoginName NVARCHAR(128) NOT NULL
				,LoginType CHAR(1) NOT NULL
				,DefaultDatabaseName NVARCHAR(128) NULL
				,PasswordHash VARBINARY(256) NULL
				,IsPolicyChecked BIT NULL
				,IsExpirationChecked BIT NULL
				,IsDisabled BIT NOT NULL
				,HasAccess BIT NOT NULL
				,DenyLogin BIT NOT NULL
				,PRIMARY KEY (LoginName,IsFromLinkedServer)
				,UNIQUE (sid,IsFromLinkedServer)
			);

			IF OBJECT_ID('tempdb..#LoginPermissions') IS NOT NULL
			BEGIN
				DROP TABLE #LoginPermissions
			END

			CREATE TABLE #LoginPermissions
			(
				IsFromLinkedServer BIT NOT NULL
				,LoginName NVARCHAR(128) NOT NULL
				,StateDescription NVARCHAR(60) NOT NULL
				,PermissionName  NVARCHAR(128) NOT NULL
				,OnClause NVARCHAR(141) NOT NULL --128 for the name + 13 for longest ON clause
				,ClassDescription NVARCHAR(60) NOT NULL
				,PRIMARY KEY(LoginName,PermissionName,OnClause,IsFromLinkedServer)
			);

			IF OBJECT_ID('tempdb..#LoginsToCreate') IS NOT NULL
			BEGIN
				DROP TABLE #LoginsToCreate
			END

			CREATE TABLE #LoginsToCreate
			(
				LoginName NVARCHAR(128) PRIMARY KEY
			);

			IF OBJECT_ID('tempdb..#LoginsToDrop') IS NOT NULL
			BEGIN
				DROP TABLE #LoginsToDrop
			END

			CREATE TABLE #LoginsToDrop
			(
				LoginName NVARCHAR(128) PRIMARY KEY
			);

			IF OBJECT_ID('tempdb..#LoginsToSkip') IS NOT NULL
			BEGIN
				DROP TABLE #LoginsToSkip
			END

			CREATE TABLE #LoginsToSkip
			(
				LoginName NVARCHAR(128) PRIMARY KEY
			);

			IF OBJECT_ID('tempdb..#RoleMembership') IS NOT NULL
			BEGIN
				DROP TABLE #RoleMembership
			END

			CREATE TABLE #RoleMembership
			(
				IsFromLinkedServer BIT NOT NULL
				,RoleName NVARCHAR(128) NOT NULL
				,PrincipalName NVARCHAR(128) NOT NULL
				,PRIMARY KEY(RoleName,PrincipalName,IsFromLinkedServer)
			);

			IF OBJECT_ID('tempdb..#SQLLoginsWhereSIDsDontMatch') IS NOT NULL
			BEGIN
				DROP TABLE #SQLLoginsWhereSIDsDontMatch
			END

			CREATE TABLE #SQLLoginsWhereSIDsDontMatch
			(
				LoginName NVARCHAR(128) PRIMARY KEY
			);

			IF OBJECT_ID('tempdb..#WorkToDo') IS NOT NULL
			BEGIN
				DROP TABLE #WorkToDo
			END

			CREATE TABLE #WorkToDo
			(
				WorkToDoID INT PRIMARY KEY IDENTITY
				,SQLToRun NVARCHAR(MAX) NOT NULL
				,Description VARCHAR(MAX)
			);
		END

		BEGIN --Parameter Verification / Utilization
			IF @LinkedServerName IS NULL
			BEGIN
				SELECT @ErrorText = 'Parameter @LinkedServerName can''t be null because bad stuff will happen'
				;THROW 50000,@ErrorText,1;
			END

			IF @CommitChanges IS NULL
			BEGIN
				SELECT @ErrorText = 'Parameter @CommitChanges can''t be null because bad stuff will happen'
				;THROW 50000,@ErrorText,1;
			END

			IF @DebugLevel IS NULL
				OR @DebugLevel < 0
			BEGIN
				SELECT @DebugLevel = 0
			END

			IF @DebugLevel > 2
			BEGIN
				SELECT @DebugLevel = 2
			END

			IF NOT EXISTS (
				SELECT 1
				FROM sys.servers s
				WHERE s.name = @LinkedServerName
			)
			BEGIN
				--We were looking for only linked servers (s.is_linked = 1), but if the server is used in replication this is not always true
				SELECT @ErrorText = 'Could not find a server with that name'
				;THROW 50000,@ErrorText,1;
			END

			IF (@@SERVERNAME = @LinkedServerName)
			BEGIN
				SELECT @ErrorText = 'Linked server cannot be the same as the server you are currently running on'
				;THROW 50000,@ErrorText,1;
			END

			IF NOT EXISTS (
				SELECT 1 
				FROM sys.dm_hadr_availability_group_states dhags
				WHERE dhags.primary_replica = @LinkedServerName
			)
			BEGIN
				SELECT @ErrorText = 'Server is not the Primary Replica'
				;THROW 50000,@ErrorText,1;
			END

			IF EXISTS (
				SELECT 1 
				FROM sys.dm_hadr_availability_group_states dhags
				WHERE dhags.primary_replica != @LinkedServerName
			)
			BEGIN
				--Mostly for future proofing if we put more than 1 Availibility group on the same server
				SELECT @ErrorText = 'There is an availibity group on this server that does not have the same primary server and syncing logins could break things'
				;THROW 50000,@ErrorText,1;
			END

			IF @CommitChanges = CONVERT(BIT,0) AND @DebugLevel = 0
			BEGIN
				SELECT @ErrorText = 'Both @CommitChanges and @DebugLevel are set to 0. Since nothing will be done or outputted the script is stopping processing'
				;THROW 50000,@ErrorText,1;
			END

			EXEC sys.sp_testlinkedserver @LinkedServerName

		END

		BEGIN --Get Data from Local Server
			INSERT INTO #BaseLoginInfo
					(
					  IsFromLinkedServer
					, sid
					, LoginName
					, LoginType
					, DefaultDatabaseName
					, PasswordHash
					, IsPolicyChecked
					, IsExpirationChecked
					, IsDisabled
					, HasAccess
					, DenyLogin
					)
			SELECT 
				0 AS IsFromLinkedServer
				,sp.sid
				,sp.name AS LoginName
				,sp.type AS LoginType
				,sp.default_database_name	
				,sl.password_hash
				,sl.is_policy_checked
				,sl.is_expiration_checked
				,sp.is_disabled
				,CASE WHEN ConnectPermissions.state IS NULL THEN 0 ELSE 1 END AS HasAccess
				,CASE WHEN ConnectPermissions.state = 'D' THEN 1 ELSE 0 END AS DenyLogin
			FROM sys.server_principals sp
			LEFT JOIN sys.sql_logins sl ON sl.sid = sp.sid
			LEFT JOIN (
				SELECT sper.grantee_principal_id AS principal_id
					,sper.state
				FROM sys.server_permissions sper
				WHERE sper.class_desc = 'SERVER'
				AND sper.permission_name = 'CONNECT SQL'
			) ConnectPermissions ON ConnectPermissions.principal_id = sp.principal_id
			WHERE sp.type IN ('S','U','G') --SQL_Login, WindowsLogin, WindowsGroups

			INSERT INTO #RoleMembership
					(
					  IsFromLinkedServer
					, RoleName
					, PrincipalName
					)
			SELECT 
				0 AS IsFromLinkedServer
				,r.name
				,sp.name
			FROM sys.server_principals r
			JOIN sys.server_role_members srm ON srm.role_principal_id = r.principal_id
			JOIN sys.server_principals sp ON sp.principal_id = srm.member_principal_id
			WHERE r.type = 'R'
			AND sp.type IN ('S','U','G')


			INSERT INTO #LoginPermissions
					(
					  IsFromLinkedServer
					, LoginName
					, StateDescription
					, PermissionName
					, OnClause
					, ClassDescription
					)
			SELECT 
				0 AS IsFromLinkedServer
				,sp.name AS LoginName
				,sper.state_desc AS StateDescription
				,sper.permission_name AS PermissionName
				,CASE 
					WHEN sper.class = 101 
						THEN ' ON LOGIN::'+QUOTENAME(sp2.name)
					WHEN sper.class = 105 
						THEN ' ON ENDPOINT::'+QUOTENAME(e.name)
					WHEN sper.class = 100 
						THEN ''
					END AS OnClause 
				,sper.class_desc AS ClassDescription
			FROM sys.server_principals sp
			JOIN sys.server_permissions sper ON sper.grantee_principal_id = sp.principal_id
			LEFT JOIN sys.server_principals sp2 
				ON sp2.principal_id = sper.major_id 
				AND sper.class = 101
			LEFT JOIN sys.endpoints e 
				ON e.endpoint_id = sper.major_id 
				AND sper.class = 105
			WHERE sp.type IN ('S','U','G')
			AND sper.permission_name != 'CONNECT SQL' --These are handled by the Login Area
		END

		BEGIN --Get Data from Linked Server
			SELECT @SQLToRun = '
					INSERT INTO #BaseLoginInfo
							(
							  IsFromLinkedServer
							, sid
							, LoginName
							, LoginType
							, DefaultDatabaseName
							, PasswordHash
							, IsPolicyChecked
							, IsExpirationChecked
							, IsDisabled
							, HasAccess
							, DenyLogin
							)
					SELECT 
						1 AS IsFromLinkedServer
						,sp.sid
						,sp.name AS LoginName
						,sp.type AS LoginType
						,sp.default_database_name	
						,sl.password_hash
						,sl.is_policy_checked
						,sl.is_expiration_checked
						,sp.is_disabled
						,CASE WHEN ConnectPermissions.state IS NULL THEN 0 ELSE 1 END AS HasAccess
						,CASE WHEN ConnectPermissions.state = ''D'' THEN 1 ELSE 0 END AS DenyLogin
					FROM '+QUOTENAME(@LinkedServerName)+'.master.sys.server_principals sp
					LEFT JOIN '+QUOTENAME(@LinkedServerName)+'.master.sys.sql_logins sl ON sl.sid = sp.sid
					LEFT JOIN (
						SELECT sper.grantee_principal_id AS principal_id
							,sper.state
						FROM '+QUOTENAME(@LinkedServerName)+'.master.sys.server_permissions sper
						WHERE sper.class_desc = ''SERVER''
						AND sper.permission_name = ''CONNECT SQL''
					) ConnectPermissions ON ConnectPermissions.principal_id = sp.principal_id
					WHERE sp.type IN (''S'',''U'',''G'') --SQL_Login, WindowsLogin, WindowsGroups
				'

			EXECUTE sys.sp_executesql @SQLToRun

			SELECT @SQLToRun ='			
				INSERT INTO #RoleMembership
						(
							IsFromLinkedServer
						, RoleName
						, PrincipalName
						)
				SELECT 
					1 AS IsFromLinkedServer
					,r.name
					,sp.name
				FROM '+QUOTENAME(@LinkedServerName)+'.master.sys.server_principals r
				JOIN '+QUOTENAME(@LinkedServerName)+'.master.sys.server_role_members srm ON srm.role_principal_id = r.principal_id
				JOIN '+QUOTENAME(@LinkedServerName)+'.master.sys.server_principals sp ON sp.principal_id = srm.member_principal_id
				WHERE r.type = ''R''
				AND sp.type IN (''S'',''U'',''G'')
			'
			EXECUTE sys.sp_executesql @SQLToRun

			SELECT @SQLToRun ='			
				INSERT INTO #LoginPermissions
						(
						  IsFromLinkedServer
						, LoginName
						, StateDescription
						, PermissionName
						, OnClause
						, ClassDescription
						)
				SELECT 
					1 AS IsFromLinkedServer
					,sp.name AS LoginName
					,sper.state_desc AS StateDescription
					,sper.permission_name AS PermissionName
					,CASE 
						WHEN sper.class = 101 
							THEN '' ON LOGIN::''+QUOTENAME(sp2.name)
						WHEN sper.class = 105 
							THEN '' ON ENDPOINT::''+QUOTENAME(e.name)
						WHEN sper.class = 100 
							THEN ''''
						END AS OnClause 
					,sper.class_desc AS ClassDescription
				FROM '+QUOTENAME(@LinkedServerName)+'.master.sys.server_principals sp
				JOIN '+QUOTENAME(@LinkedServerName)+'.master.sys.server_permissions sper ON sper.grantee_principal_id = sp.principal_id
				LEFT JOIN '+QUOTENAME(@LinkedServerName)+'.master.sys.server_principals sp2 
					ON sp2.principal_id = sper.major_id 
					AND sper.class = 101
				LEFT JOIN '+QUOTENAME(@LinkedServerName)+'.master.sys.endpoints e 
					ON e.endpoint_id = sper.major_id 
					AND sper.class = 105
				WHERE sp.type IN (''S'',''U'',''G'')
				AND sper.permission_name != ''CONNECT SQL'' --These are handled by the Login Area
			'
			EXECUTE sys.sp_executesql @SQLToRun


		END
		
		BEGIN --Determine login's to Skip
			INSERT INTO #LoginsToSkip
					( LoginName )
			SELECT bli.LoginName
			FROM #BaseLoginInfo bli
			WHERE 
				--sa even if it is renamed 
				bli.sid = '0x01'
				-- system logins to skip
				OR bli.LoginName LIKE '##%'
				OR bli.LoginName LIKE 'BUILTIN%'
				OR bli.LoginName LIKE 'NT %'
				--Common Names we know we dont want to adjust
				OR bli.LoginName IN (
					'sa'
					,'distributor_admin'
					)
				--Local Users
				OR (
					bli.LoginName LIKE @@SERVERNAME+'\%'
					AND bli.IsFromLinkedServer = 0
					)
				OR (
					bli.LoginName LIKE @LinkedServerName+'\%'
					AND bli.IsFromLinkedServer = 1
					)
				--Logins we know we want to skip
				OR EXISTS (
					SELECT 1
					FROM dbo.LoginsNotToSync lnts
					WHERE lnts.LoginName = bli.LoginName
				)
			GROUP BY bli.LoginName
		END
		
		BEGIN --Figure out if a SQL Login needs to be recreated due to the SIDs not matching


			INSERT INTO #SQLLoginsWhereSIDsDontMatch
					( LoginName )
			SELECT ISNULL(bli0.LoginName,bli1.LoginName) LoginName
			FROM (
				SELECT bli.LoginName
					,bli.sid
				FROM #BaseLoginInfo bli
				WHERE bli.IsFromLinkedServer = CONVERT(BIT,0)
				AND bli.LoginType = 'S'
				AND NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE bli.LoginName = lts.LoginName
				)
			) bli0
			JOIN (
				SELECT bli2.LoginName
					,bli2.sid
				FROM #BaseLoginInfo bli2
				WHERE bli2.IsFromLinkedServer = CONVERT(BIT,1)
				AND bli2.LoginType = 'S'
				AND NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts2
					WHERE bli2.LoginName = lts2.LoginName
				)
			) bli1 ON bli1.LoginName = bli0.LoginName
			WHERE bli0.sid != bli1.sid

		END

		BEGIN --DROP/CREATE/UPDATE logins
			
			BEGIN --Drop Logic
				--Saving these off to a table to that we do not do Role/Permission changes for these logins
				INSERT INTO #LoginsToDrop
						( LoginName )
				SELECT bli0.LoginName
				FROM #BaseLoginInfo bli0
				WHERE bli0.IsFromLinkedServer = CONVERT(BIT,0)
				AND NOT EXISTS (
					--Obviously if we are skipping them then we wouldnt drop them
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE bli0.LoginName = lts.LoginName
				)
				AND (
					/*
						Logins need to either only exist on the Local side 
						or they have to be a SQL Login that is being remapped
					*/
					NOT EXISTS (
						SELECT 1
						FROM #BaseLoginInfo bli1
						WHERE bli1.IsFromLinkedServer = CONVERT(BIT,1) 
						AND bli1.LoginName = bli0.LoginName
					)
					OR EXISTS (
						SELECT 1
						FROM #SQLLoginsWhereSIDsDontMatch slwsddm
						WHERE slwsddm.LoginName = bli0.LoginName
					)
				)

				INSERT INTO #WorkToDo
						( SQLToRun, Description )
				SELECT 'DROP LOGIN '+QUOTENAME(ltd.LoginName) AS SQLToRun
					,CASE 
						WHEN EXISTS (
							SELECT 1
							FROM #SQLLoginsWhereSIDsDontMatch slwsddm
							WHERE slwsddm.LoginName = ltd.LoginName
						)
							THEN 'Dropping login because they need to have their SID remapped'
						ELSE 'Dropping login because they do not exist on the linked server'
						END AS Description
				FROM #LoginsToDrop ltd
				ORDER BY ltd.LoginName

			END
			
			BEGIN --Create Logins
				--Saving these off to a table to that we add all Roles/Permissions for these logins
				INSERT INTO #LoginsToCreate
						( LoginName )
				SELECT bli1.LoginName
				FROM #BaseLoginInfo bli1
				WHERE bli1.IsFromLinkedServer = CONVERT(BIT,1)
				AND NOT EXISTS (
					--Obviously if we are skipping them then we wouldnt add them
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE bli1.LoginName = lts.LoginName
				)
				AND (
					/*
						Logins need to either only exist on the Linked Server side 
						or they have to be a SQL Login that is being remapped
					*/
					NOT EXISTS (
						SELECT 1
						FROM #BaseLoginInfo bli0
						WHERE bli0.IsFromLinkedServer = CONVERT(BIT,0) 
						AND bli0.LoginName = bli1.LoginName
					)
					OR EXISTS (
						SELECT 1
						FROM #SQLLoginsWhereSIDsDontMatch slwsddm
						WHERE slwsddm.LoginName = bli1.LoginName
					)
				)

				INSERT INTO #WorkToDo
						( SQLToRun, Description )
				/*
					Most of this logic was taken from work I did a while ago where I converted the sp_help_revlogin SP to be 1 select statement instead of a while loop
						sp_help_revlogin Found Here: https://support.microsoft.com/en-us/kb/918992
						and here: https://support.microsoft.com/en-us/help/918992/how-to-transfer-logins-and-passwords-between-instances-of-sql-server
				*/
				
				SELECT --Create Login
					CASE 
						WHEN bli1.LoginType IN ( 'U','G')
							THEN 'CREATE LOGIN ' + QUOTENAME( bli1.LoginName ) + ' FROM WINDOWS WITH DEFAULT_DATABASE = ' + QUOTENAME( bli1.DefaultDatabaseName ) + ''
						WHEN bli1.LoginType = 'S'
							THEN 'CREATE LOGIN ' + QUOTENAME( bli1.LoginName ) 
									+' WITH PASSWORD = '+CONVERT(NVARCHAR(MAX),bli1.PasswordHash,1)+' HASHED'
									+', SID = '+CONVERT(NVARCHAR(MAX),bli1.sid,1)
									+', DEFAULT_DATABASE = '+QUOTENAME( bli1.DefaultDatabaseName )
									+CASE 
										WHEN bli1.IsPolicyChecked IS NULL
											THEN '' 
										WHEN bli1.IsPolicyChecked = 1
											THEN ', CHECK_POLICY = ON'
										WHEN bli1.IsPolicyChecked = 0
											THEN ', CHECK_POLICY = OFF'
										END
									+CASE 
										WHEN bli1.IsExpirationChecked IS NULL
											THEN '' 
										WHEN bli1.IsExpirationChecked = 1
											THEN ', CHECK_EXPIRATION = ON'
										WHEN bli1.IsExpirationChecked = 0
											THEN ', CHECK_EXPIRATION = OFF'
										END
					END
					--Deny/Revoke/Disable as needed
					+ CASE 
						WHEN bli1.DenyLogin = 1
							THEN '; DENY CONNECT SQL TO '+QUOTENAME( bli1.LoginName )
						ELSE ''
						END
					+ CASE 
						WHEN bli1.HasAccess = 0
							THEN '; REVOKE CONNECT SQL TO '+QUOTENAME( bli1.LoginName )
						ELSE ''
						END
					+ CASE 
						WHEN bli1.IsDisabled = 1
							THEN '; ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) + ' DISABLE'
						ELSE ''
						END
						AS SQLToRun
					,CASE 
						WHEN EXISTS (
							SELECT 1
							FROM #SQLLoginsWhereSIDsDontMatch slwsddm
							WHERE slwsddm.LoginName = ltc.LoginName
						)
							THEN 'Creating login because they need to have their SID remapped'
						ELSE 'Creating login because they do not exist on the local server'
						END AS Description
				FROM #LoginsToCreate ltc
				JOIN #BaseLoginInfo bli1 ON bli1.LoginName = ltc.LoginName
				WHERE bli1.IsFromLinkedServer = CONVERT(BIT,1)
				ORDER BY ltc.LoginName
			END

			BEGIN --ALTER LOGINs logic
				/*
					Checks if the any of the following need to be updated
						Default Database
						Password
						Policy Checked
						Expiration of the policy check
						If the account needs to be disabled/enabled
						Or if the connect permissions needd to be updated
				*/
				INSERT INTO #WorkToDo
						( SQLToRun, Description )
				SELECT AlterWork.AlterDefaultDatabase
					 + AlterWork.AlterPassword
					 + AlterWork.AlterPolicyChecked
					 + AlterWork.AlterExpirationChecked
					 + AlterWork.AlterDisabled
					 + AlterWork.AlterConnectPermissions
					,'ALTER LOGIN logic. Sids and login names matched but something else did not'
				FROM (
					SELECT 
						CASE 
							WHEN bli0.DefaultDatabaseName != bli1.DefaultDatabaseName
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) + ' WITH DEFAULT_DATABASE = '+QUOTENAME( bli1.DefaultDatabaseName )+';'
							ELSE ''
						END AS AlterDefaultDatabase
						,CASE 
							WHEN bli0.LoginType = 'S'
								AND bli1.LoginType = 'S'
								AND bli0.PasswordHash != bli1.PasswordHash 
								AND ISNULL(bli0.IsPolicyChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
								/*
									You cant alter the hashed password if CheckPolicy is turned on so we will turn it off before the alter and then re-enable it
								*/
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) +' WITH CHECK_POLICY=OFF;'+'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) +' WITH PASSWORD = '+CONVERT(NVARCHAR(MAX),bli1.PasswordHash,1)+' HASHED;' 
							WHEN bli0.LoginType = 'S'
								AND bli1.LoginType = 'S'
								AND bli0.PasswordHash != bli1.PasswordHash 
								AND ISNULL(bli0.IsPolicyChecked,CONVERT(BIT,0)) != CONVERT(BIT,1)
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) +' WITH PASSWORD = '+CONVERT(NVARCHAR(MAX),bli1.PasswordHash,1)+' HASHED;' 
							ELSE '' 
						END AS AlterPassword
						, CASE
							WHEN bli0.LoginType = 'S'
								AND bli1.LoginType = 'S'
								AND 
								(
									(	
										ISNULL(bli0.IsPolicyChecked,CONVERT(BIT,0)) = CONVERT(BIT,0)
										AND ISNULL(bli1.IsPolicyChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
									)
									OR (
										--If the password needed to be update we have to temporarily disable the check policy/expration and this turns it back on
										ISNULL(bli0.IsPolicyChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
										AND ISNULL(bli1.IsPolicyChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
										AND bli0.PasswordHash != bli1.PasswordHash 
									)
								)
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) +' WITH CHECK_POLICY=ON;'
							WHEN bli0.LoginType = 'S'
								AND bli1.LoginType = 'S'
								AND ISNULL(bli0.IsPolicyChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
								AND ISNULL(bli1.IsPolicyChecked,CONVERT(BIT,0)) = CONVERT(BIT,0)
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) +' WITH CHECK_POLICY=OFF;'
							ELSE ''
						END AS AlterPolicyChecked
						,CASE 
							WHEN bli0.LoginType = 'S'
								AND bli1.LoginType = 'S'
								AND 
								(
									(
										ISNULL(bli0.IsExpirationChecked,CONVERT(BIT,0)) = CONVERT(BIT,0)
										AND ISNULL(bli1.IsExpirationChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
									)
									OR (
										--If the password needed to be update we have to temporarily disable the check policy/expration and this turns it back on
										ISNULL(bli0.IsExpirationChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
										AND ISNULL(bli1.IsExpirationChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
										AND bli0.PasswordHash != bli1.PasswordHash 
									)
								)
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) +' WITH CHECK_EXPIRATION=ON;'
							WHEN bli0.LoginType = 'S'
								AND bli1.LoginType = 'S'
								AND ISNULL(bli0.IsExpirationChecked,CONVERT(BIT,0)) = CONVERT(BIT,1)
								AND ISNULL(bli1.IsExpirationChecked,CONVERT(BIT,0)) = CONVERT(BIT,0)
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) +' WITH CHECK_EXPIRATION=OFF;'
							ELSE ''
						END AS AlterExpirationChecked
						,CASE 
							WHEN bli0.IsDisabled = CONVERT(BIT,0)
								AND bli1.IsDisabled = CONVERT(BIT,1)
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) + ' DISABLE;'
							WHEN bli0.IsDisabled = CONVERT(BIT,1)
								AND bli1.IsDisabled = CONVERT(BIT,0)
								THEN 'ALTER LOGIN ' + QUOTENAME( bli1.LoginName ) + ' ENABLE;'
							ELSE ''
						END AS AlterDisabled
						,CASE 
							/*
								This took me a little bit to think about. This is what I am trying to do

								There are 3 options on each side across the 2 variables due to how it is determined

								Below is a spreadsheet of the possible options

								+-----------------------------------+----------------------------------+-----------+
								|          Linked Server            |              Local Server        |           |
								+---------------+-----------+-------+--------------+-----------+-------+-----------+
								| HasAccess     | DenyLogin | Type  | HasAccess    | DenyLogin | Type  | Job To Do |
								+---------------+-----------+-------+--------------+-----------+-------+-----------+
								| 1             | 1         | DENY  | 1            | 0         | GRANT | Deny      |
								| 1             | 1         | DENY  | 0            | 0         | NULL  | Deny      |
								| 1             | 0         | GRANT | 0            | 0         | NULL  | Grant     |
								| 1             | 0         | GRANT | 1            | 1         | DENY  | Grant     |
								| 1             | 0         | GRANT | 1            | 0         | GRANT | Nothing   |
								| 0             | 0         | NULL  | 0            | 0         | NULL  | Nothing   |
								| 1             | 1         | DENY  | 1            | 1         | DENY  | Nothing   |
								| 0             | 0         | NULL  | 1            | 0         | GRANT | Revoke    |
								| 0             | 0         | NULL  | 1            | 1         | DENY  | Revoke    |
								+---------------+-----------+-------+--------------+-----------+-------+-----------+
							*/
							WHEN bli0.HasAccess = bli1.HasAccess
								AND bli0.DenyLogin = bli1.DenyLogin
								THEN '' --Do Nothing
							WHEN bli1.DenyLogin = 1 
								AND bli0.DenyLogin = 0
								THEN 'DENY CONNECT SQL TO '+QUOTENAME( bli1.LoginName ) +';'
							WHEN bli1.HasAccess = 0 
								AND bli0.HasAccess = 1
								THEN 'REVOKE CONNECT SQL TO '+QUOTENAME( bli1.LoginName ) +';'
							WHEN bli1.HasAccess = 1
								AND bli1.DenyLogin = 0
								AND (
									bli0.HasAccess != bli1.HasAccess
									OR bli0.DenyLogin != bli1.DenyLogin
								)
								THEN 'GRANT CONNECT SQL TO '+QUOTENAME( bli1.LoginName ) +';'
							ELSE 'THROW 50000,''This Should Never Happen'',1;'
						END AS AlterConnectPermissions
					FROM #BaseLoginInfo bli0
					JOIN #BaseLoginInfo bli1 
						/*
							Since we are joining on sid and Login name we dont need to worry about items that are 
							only on one side or those that are getting redone because the SID needs to be redone
						*/
						ON bli1.sid = bli0.sid
						AND bli1.LoginName = bli0.LoginName
					WHERE bli0.IsFromLinkedServer = CONVERT(BIT,0)
					AND bli1.IsFromLinkedServer = CONVERT(BIT,1)
					AND NOT EXISTS (
						--Does a check to see if something mis-matches
						SELECT 
							bli0.DefaultDatabaseName
							, bli0.PasswordHash
							, ISNULL(bli0.IsPolicyChecked,CONVERT(BIT,0))
							, ISNULL(bli0.IsExpirationChecked,CONVERT(BIT,0))
							, bli0.IsDisabled
							, bli0.HasAccess
							, bli0.DenyLogin
						INTERSECT
						SELECT
							bli1.DefaultDatabaseName
							, bli1.PasswordHash
							, ISNULL(bli1.IsPolicyChecked,CONVERT(BIT,0))
							, ISNULL(bli1.IsExpirationChecked,CONVERT(BIT,0))
							, bli1.IsDisabled
							, bli1.HasAccess
							, bli1.DenyLogin
					)
					AND NOT EXISTS (
						--Filter Out the ones you are going to skip
						SELECT 1
						FROM #LoginsToSkip lts
						WHERE lts.LoginName = bli0.LoginName
					)
				) AlterWork
			END
		END

		BEGIN --Check if Dropped Logins own any sql agent jobs or databases
			IF EXISTS (
				SELECT 1
				FROM #LoginsToDrop ltd
				JOIN #BaseLoginInfo bli ON bli.LoginName = ltd.LoginName
				JOIN sys.databases d ON d.owner_sid = bli.sid
				WHERE bli.IsFromLinkedServer = CONVERT(BIT,0)
			)
			BEGIN
				SELECT @ErrorText = 'One of the logins that will be drops own a database. Please fix this before continuing'
				;THROW 50000,@ErrorText,1;
			END

			IF EXISTS (
				SELECT 1
				FROM #LoginsToDrop ltd
				JOIN #BaseLoginInfo bli ON bli.LoginName = ltd.LoginName
				JOIN msdb.dbo.sysjobs j ON j.owner_sid = bli.sid
				WHERE bli.IsFromLinkedServer = CONVERT(BIT,0)
			)
			BEGIN
				SELECT @ErrorText = 'One of the logins that will be drops own SQL Agent Job. Please fix this before continuing'
				;THROW 50000,@ErrorText,1;
			END

		END
		
		BEGIN --Do Server Roles Work
			
			--Check to make sure that all of the roles that you will be uses exist
			IF EXISTS (
				SELECT 1
				FROM #RoleMembership rm
				WHERE rm.IsFromLinkedServer = 1
				AND NOT EXISTS (
					SELECT 1
					FROM sys.server_principals r
					WHERE r.type = 'R'
					AND rm.RoleName = r.name
				)
				AND NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = rm.PrincipalName
				)
			)
			BEGIN

				SELECT @ErrorText = STUFF (
					(
						SELECT ',('+rm.PrincipalName+' uses '+rm.RoleName+')'
						FROM #RoleMembership rm
						WHERE rm.IsFromLinkedServer = 1
						AND NOT EXISTS (
							SELECT 1
							FROM sys.server_principals r
							WHERE r.type = 'R'
							AND rm.RoleName = r.name
						)
						AND NOT EXISTS (
							SELECT 1
							FROM #LoginsToSkip lts
							WHERE lts.LoginName = rm.PrincipalName
						)	
						FOR XML PATH ('')
					)
					,1,1,'') + 'One of the logins on the linked server is using a role that does not exist on the local server. This process does not create/modify roles at this time please create and setup the permissions on this role manually and re-run'
				;THROW 50000,@ErrorText,1;
			END

			INSERT INTO #WorkToDo
					( SQLToRun, Description )
			SELECT 
				CASE 
					WHEN Local.RoleName IS NOT NULL
						THEN 'ALTER SERVER ROLE '+QUOTENAME(Local.RoleName)+' DROP MEMBER '+QUOTENAME(Local.PrincipalName)+';'
					WHEN Linked.RoleName IS NOT NULL
						THEN 'ALTER SERVER ROLE '+QUOTENAME(Linked.RoleName)+' ADD MEMBER '+QUOTENAME(Linked.PrincipalName)+ ';'
					END
				,'Adding Or Removing the appropriate role membership'
			FROM (
				SELECT rm0.RoleName
					 , rm0.PrincipalName
				FROM #RoleMembership rm0
				WHERE rm0.IsFromLinkedServer = 0
				AND NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts0
					WHERE lts0.LoginName = rm0.PrincipalName
				)
				AND NOT EXISTS (
					/*
						This does 2 things
							1. makes it so that we dont remove roles on logins we are dropping anyway
							2. Since they are not on the "local" side it makes it so that we reapply all roles from the linked server
								- Helpful when droping and recreating due to SID not matching
					*/
					SELECT 1
					FROM #LoginsToDrop ltd0
					WHERE ltd0.LoginName = rm0.PrincipalName
				)
			) Local
			FULL JOIN (
				SELECT rm1.RoleName
					 , rm1.PrincipalName
				FROM #RoleMembership rm1
				WHERE rm1.IsFromLinkedServer = 1
				AND NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts1
					WHERE lts1.LoginName = rm1.PrincipalName
				)
			) Linked 
				ON Linked.PrincipalName = Local.PrincipalName
				AND Linked.RoleName = Local.RoleName
			WHERE Linked.RoleName IS NULL
				OR Local.RoleName IS NULL
		END

		BEGIN --Do Server Permissions Work
			IF EXISTS (
				SELECT 1
				FROM #LoginPermissions lp
				WHERE NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = lp.LoginName
				)
				AND lp.StateDescription = 'GRANT_WITH_GRANT_OPTION'
			)
			BEGIN 
				/*
					For the future: 
					If we want to use GRANT_WITH_GRANT_OPTION we will need to work this out to Add the WITH GRANT OPTION and CASCADES
					Also we will want to look into a way to make sure the Grantor gets set correctly
				*/
				SELECT @ErrorText = 'One of the sides has a GRANT_WITH_GRANT_OPTION permission. This script does not handle that. See notes in the SP for more info.'	
				;THROW 50000,@ErrorText,1;
			END

			INSERT INTO #WorkToDo
					( SQLToRun, Description )
			SELECT 
				CASE 
					WHEN Linked.StateDescription != Local.StateDescription
						OR Local.LoginName IS NULL
						THEN Linked.StateDescription + ' ' + Linked.PermissionName + Linked.OnClause + ' TO '+ QUOTENAME(Linked.LoginName)+';'
					WHEN Linked.LoginName IS NULL
						THEN 'REVOKE ' + Local.PermissionName  + Local.OnClause + ' TO '+ QUOTENAME(Local.LoginName)+';'
					END
					,'Permissions work'
			FROM (
				SELECT lp0.LoginName
					 , lp0.StateDescription
					 , lp0.PermissionName
					 , lp0.OnClause
					 , lp0.ClassDescription
				FROM #LoginPermissions lp0
				WHERE lp0.IsFromLinkedServer = 0
				AND NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts0
					WHERE lts0.LoginName = lp0.LoginName
				)
				AND NOT EXISTS (
					/*
						This does 2 things
							1. makes it so that we dont remove permissions on logins we are dropping anyway
							2. Since they are not on the "local" side it makes it so that we reapply all permissions from the linked server
								- Helpful when droping and recreating due to SID not matching
					*/
					SELECT 1
					FROM #LoginsToDrop ltd0
					WHERE ltd0.LoginName = lp0.LoginName
				)
			) Local
			FULL JOIN (
				SELECT lp1.LoginName
					 , lp1.StateDescription
					 , lp1.PermissionName
					 , lp1.OnClause
					 , lp1.ClassDescription
				FROM #LoginPermissions lp1
				WHERE lp1.IsFromLinkedServer = 1
				AND NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts1
					WHERE lts1.LoginName = lp1.LoginName
				)
			) Linked
				ON Linked.LoginName = Local.LoginName
				AND Linked.PermissionName = Local.PermissionName
				AND Linked.ClassDescription = Local.ClassDescription
				AND Linked.OnClause = Local.OnClause
			WHERE Linked.StateDescription != Local.StateDescription
			OR Linked.LoginName IS NULL
			OR Local.LoginName IS NULL

		END

		BEGIN --Debugging
			/*
				The Debugging code is in the TRY and the CATCH. Be sure to update both areas when you make a change
			*/
		
			IF @DebugLevel >= 1
			BEGIN
				SELECT 'Work To Do' AS TableDescription
					, wtd.WorkToDoID
					, wtd.SQLToRun
					, wtd.Description
				FROM #WorkToDo wtd
			END

			IF @DebugLevel = 2
			BEGIN
				SELECT 'LoginsToSkip' AS TableDescription 
					,lts.LoginName
				FROM #LoginsToSkip lts
				UNION ALL
				SELECT 'SQLLoginsWhereSIDsDontMatch' AS TableDescription 
					,slwsddm.LoginName
				FROM #SQLLoginsWhereSIDsDontMatch slwsddm
				UNION ALL
				SELECT  'LoginsToCreate' AS TableDescription 
					, ltc.LoginName
				FROM #LoginsToCreate ltc
				UNION ALL
				SELECT 'LoginsToDrop' AS TableDescription 
					, ltd.LoginName
				FROM #LoginsToDrop ltd

				SELECT 'BaseLoginInfo minus SkippedLogins' AS TableDescription 
					,bli.IsFromLinkedServer
					, bli.sid
					, bli.LoginName
					, bli.LoginType
					, bli.DefaultDatabaseName
					, bli.PasswordHash
					, bli.IsPolicyChecked
					, bli.IsExpirationChecked
					, bli.IsDisabled
					, bli.HasAccess
					, bli.DenyLogin
				FROM #BaseLoginInfo bli
				WHERE NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = bli.LoginName
				) 

				SELECT 'RoleMembership minus SkippedLogins' AS TableDescription 
					,rm.IsFromLinkedServer
					, rm.RoleName
					, rm.PrincipalName
				FROM #RoleMembership rm
				WHERE NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = rm.PrincipalName
				) 

				SELECT 'LoginPermissions minus SkippedLogins' AS TableDescription 
					, lp.IsFromLinkedServer
					, lp.LoginName
					, lp.StateDescription
					, lp.PermissionName
					, lp.OnClause
					, lp.ClassDescription
				FROM #LoginPermissions lp
				WHERE NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = lp.LoginName
				) 
			END
		END

		BEGIN --Process the work to do
			IF @CommitChanges = CONVERT(BIT,1)
			BEGIN
				BEGIN TRANSACTION

				SELECT @MaxWorkToDoID = MAX(wtd.WorkToDoID)
				FROM #WorkToDo wtd

				SELECT @MaxWorkToDoID = ISNULL(@MaxWorkToDoID,0)
					,@CurrentWorkToDoID = 1
					
				INSERT INTO dbo.SyncLoginsFromLinkedServerLog
						( SQLToRun, Description )
				VALUES	
					( '--There are '+CONVERT(VARCHAR(11),@MaxWorkToDoID)+' items to Process','Starting Work To Do')

				INSERT INTO dbo.SyncLoginsFromLinkedServerLog
						( SQLToRun, Description )
				SELECT wtd.SQLToRun
					 , wtd.Description
				FROM #WorkToDo wtd
				ORDER BY wtd.WorkToDoID

				WHILE @CurrentWorkToDoID <= @MaxWorkToDoID
				BEGIN

					SELECT @SQLToRun = wtd.SQLToRun
					FROM #WorkToDo wtd
					WHERE wtd.WorkToDoID = @CurrentWorkToDoID

					EXEC sys.sp_executesql @SQLToRun

					SELECT @CurrentWorkToDoID = @CurrentWorkToDoID + 1
				END

				INSERT INTO dbo.SyncLoginsFromLinkedServerLog
						( SQLToRun, Description )
				VALUES	
					( '--'+CONVERT(VARCHAR(11),@CurrentWorkToDoID-1)+' items were processed','End of Work To Do')

				--ROLLBACK TRANSACTION
				COMMIT TRANSACTION
			END
		END

	END TRY
	BEGIN CATCH

		BEGIN --Debugging
			/*
				The Debugging code is in the TRY and the CATCH. Be sure to update both areas when you make a change
			*/
		
			IF @DebugLevel >= 1
			BEGIN
				SELECT 'Work To Do' AS TableDescription
					, wtd.WorkToDoID
					, wtd.SQLToRun
					, wtd.Description
				FROM #WorkToDo wtd
			END

			IF @DebugLevel = 2
			BEGIN
				SELECT 'LoginsToSkip' AS TableDescription 
					,lts.LoginName
				FROM #LoginsToSkip lts
				UNION ALL
				SELECT 'SQLLoginsWhereSIDsDontMatch' AS TableDescription 
					,slwsddm.LoginName
				FROM #SQLLoginsWhereSIDsDontMatch slwsddm
				UNION ALL
				SELECT  'LoginsToCreate' AS TableDescription 
					, ltc.LoginName
				FROM #LoginsToCreate ltc
				UNION ALL
				SELECT 'LoginsToDrop' AS TableDescription 
					, ltd.LoginName
				FROM #LoginsToDrop ltd

				SELECT 'BaseLoginInfo minus SkippedLogins' AS TableDescription 
					,bli.IsFromLinkedServer
					, bli.sid
					, bli.LoginName
					, bli.LoginType
					, bli.DefaultDatabaseName
					, bli.PasswordHash
					, bli.IsPolicyChecked
					, bli.IsExpirationChecked
					, bli.IsDisabled
					, bli.HasAccess
					, bli.DenyLogin
				FROM #BaseLoginInfo bli
				WHERE NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = bli.LoginName
				) 

				SELECT 'RoleMembership minus SkippedLogins' AS TableDescription 
					,rm.IsFromLinkedServer
					, rm.RoleName
					, rm.PrincipalName
				FROM #RoleMembership rm
				WHERE NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = rm.PrincipalName
				) 

				SELECT 'LoginPermissions minus SkippedLogins' AS TableDescription 
					, lp.IsFromLinkedServer
					, lp.LoginName
					, lp.StateDescription
					, lp.PermissionName
					, lp.OnClause
					, lp.ClassDescription
				FROM #LoginPermissions lp
				WHERE NOT EXISTS (
					SELECT 1
					FROM #LoginsToSkip lts
					WHERE lts.LoginName = lp.LoginName
				) 
			END
		END

		IF @@TRANCOUNT > 0
		BEGIN
			ROLLBACK;
		END;

		INSERT INTO dbo.SyncLoginsFromLinkedServerLog
				( SQLToRun, Description )
		SELECT  ERROR_MESSAGE(), 'Error';

		THROW;
	END CATCH
END



GO


