IF EXISTS (
		SELECT 1
		FROM sys.triggers
		WHERE parent_class = 0
			AND NAME = 'PermissionTrigger'
		)
	DROP TRIGGER PermissionTrigger ON DATABASE;
GO

CREATE TRIGGER PermissionTrigger ON DATABASE
FOR GRANT_DATABASE AS
BEGIN
	--Does a check if the permissions are being assigned to a user (Both SQL and Windows)
	IF EXISTS (
			SELECT 1
			FROM (
				--List of Grantee's from the EventData
				SELECT Grantee.value('(text())[1]', 'nvarchar(128)') AS PrincipalName
				FROM (SELECT EVENTDATA() AS XMLData) x
				CROSS APPLY x.XMLData.nodes('//EVENT_INSTANCE/Grantees/Grantee') AS Grantees(Grantee)
				) G
			JOIN sys.database_principals dp ON dp.NAME = g.PrincipalName
			WHERE dp.type IN ('S','U') --SQL Users and Windows Users
			)
	BEGIN
		RAISERROR ('You can not assign permissions to a user. If you think it is in error please contact a DBA',10,1)
		ROLLBACK
	END
END
GO
