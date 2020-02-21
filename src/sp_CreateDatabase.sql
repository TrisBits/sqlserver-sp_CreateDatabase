USE [msdb]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- Drop stored procedure if already exists
IF EXISTS (SELECT [name] FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[sp_CreateDatabase]') AND type in (N'P', N'PC'))
BEGIN
	DROP PROCEDURE [dbo].[sp_CreateDatabase]
END
GO


CREATE PROCEDURE [dbo].[sp_CreateDatabase] 

	-- Parameters for the stored procedure
	@DbName NVARCHAR(256),
	@DbRecoveryMode NVARCHAR(11) = 'Simple',
	@DbCollation NVARCHAR(256) = NULL,
	@DataSizeMB INT = 2048,
	@LogSizeMB INT = NULL
WITH EXECUTE AS OWNER
AS
SET NOCOUNT ON;

DECLARE @DefaultDataPath NVARCHAR(256);
DECLARE @DefaultLogPath NVARCHAR(256);
DECLARE @SqlStatement NVARCHAR(4000);
DECLARE	@DataAutoGrowth INT;
DECLARE	@LogAutoGrowth INT;


-- Perform validation on the DbRecoveryMode parameter
IF @DbRecoveryMode NOT IN ('Full', 'Simple')
BEGIN
	RAISERROR(N'DbRecoverMode must be set to either Full or Simple',16,1)
	RETURN
END
ELSE IF @DbRecoveryMode IS NULL
BEGIN
	SET @DbRecoveryMode = 'Simple'
END


-- Perform validation on the DataSizeMB parameter
IF @DataSizeMB IS NULL
BEGIN
	SET @DataSizeMB = 2048
END
ELSE IF @DataSizeMB < 32
BEGIN
	RAISERROR(N'DataSizeMB must be no smaller than 32',16,1)
	RETURN
END
ELSE IF (@DataSizeMB%8) <> 0
BEGIN
	RAISERROR(N'DataSizeMB must be a value divisible by 8 (ex: 128, 1024, 2048)',16,1)
	RETURN
END

-- Perform validation on the LogSizeMB parameter
IF @LogSizeMB IS NULL
BEGIN
	SET @LogSizeMB = @DataSizeMB/2
END
ELSE IF @LogSizeMB < 8
BEGIN
	RAISERROR(N'LogSizeMB must be no smaller than 8',16,1)
	RETURN
END
ELSE IF @LogSizeMB > @DataSizeMB
BEGIN
	RAISERROR(N'LogSizeMB can not be larger than DataSizeMB',16,1)
	RETURN
END
ELSE IF (@LogSizeMB%8) <> 0
BEGIN
	RAISERROR(N'LogSizeMB must be a value divisible by 8 (ex: 64, 128, 1024, 2048)',16,1)
	RETURN
END


-- Determine Autogrowth sizes
SET @DataAutoGrowth = 
	CASE
		WHEN @DataSizeMB <= 512 THEN 128
		WHEN @DataSizeMB > 512 AND @DataSizeMB <= 1024 THEN 256
		WHEN @DataSizeMB > 1024 AND @DataSizeMB <= 20480 THEN 512
		WHEN @DataSizeMB > 20480 THEN 1024
	END;

SET @LogAutoGrowth = 
	CASE
		WHEN @LogSizeMB <= 256 THEN 128
		WHEN @LogSizeMB > 256 AND @LogSizeMB <= 10240 THEN 512
		WHEN @DataSizeMB > 10240 THEN 1024
	END;


-- Get the default paths to create the database
SET @DefaultDataPath = (CONVERT(nvarchar(256), (SELECT serverproperty('InstanceDefaultDataPath'))));
SET @DefaultLogPath = (CONVERT(nvarchar(256), (SELECT serverproperty('InstanceDefaultLogPath'))));


-- Set database collation to server default if not specified
If @DbCollation IS NULL
BEGIN
	SET @DbCollation = (SELECT CONVERT (varchar(256), SERVERPROPERTY('collation')));
END


-- Create the database with PRIMARY and DATA filegroup, set DATA as default filegroup, enable Query Store, AUTOGROW_ALL_FILES
SET @SqlStatement = '
CREATE DATABASE [' + @DbName + '] CONTAINMENT = NONE ON  PRIMARY 
-- Primary File Group holds system meta data, kept small so database comes online faster
( NAME = N''' + @DbName + '_Primary'', FILENAME = N''' + @DefaultDataPath + @DbName + '_Primary.mdf'' , SIZE = 8MB , FILEGROWTH = 8MB ),
-- Secondary File Group holds user data
FILEGROUP DATA
( NAME = N''' + @DbName + '_Data01'', FILENAME = N''' + @DefaultDataPath + @DbName + '_Data01.ndf'' , SIZE = 8MB , FILEGROWTH = ' + (CONVERT(nvarchar(256),@DataAutoGrowth)) + 'MB ),
( NAME = N''' + @DbName + '_Data02'', FILENAME = N''' + @DefaultDataPath + @DbName + '_Data02.ndf'' , SIZE = 8MB , FILEGROWTH = ' + (CONVERT(nvarchar(256),@DataAutoGrowth)) + 'MB ),
( NAME = N''' + @DbName + '_Data03'', FILENAME = N''' + @DefaultDataPath + @DbName + '_Data03.ndf'' , SIZE = 8MB , FILEGROWTH = ' + (CONVERT(nvarchar(256),@DataAutoGrowth)) + 'MB ),
( NAME = N''' + @DbName + '_Data04'', FILENAME = N''' + @DefaultDataPath + @DbName + '_Data04.ndf'' , SIZE = 8MB , FILEGROWTH = ' + (CONVERT(nvarchar(256),@DataAutoGrowth)) + 'MB )
 LOG ON 
( NAME = N''' + @DbName + '_Log'', FILENAME = N''' + @DefaultLogPath + @DbName + '_Log.ldf'' , SIZE = 8MB , FILEGROWTH = ' + (CONVERT(nvarchar(256),@LogAutoGrowth)) + 'MB )
 COLLATE ' + @DbCollation + ';

ALTER DATABASE [' + @DbName + '] MODIFY FILEGROUP [PRIMARY] AUTOGROW_ALL_FILES;
ALTER DATABASE [' + @DbName + '] MODIFY FILEGROUP [DATA] AUTOGROW_ALL_FILES;
ALTER DATABASE [' + @DbName + '] SET RECOVERY ' + @DbRecoveryMode + ';
IF NOT EXISTS (SELECT name FROM ' + @DbName + '.sys.filegroups WHERE is_default=1 AND name = N''DATA'') ALTER DATABASE [' + @DbName + '] MODIFY FILEGROUP [DATA] DEFAULT
ALTER DATABASE [' + @DbName + '] SET QUERY_STORE = ON
ALTER DATABASE [' + @DbName + '] SET QUERY_STORE (OPERATION_MODE = READ_WRITE, MAX_STORAGE_SIZE_MB = 1024, QUERY_CAPTURE_MODE = AUTO)
'

-- Expand Data files to desired size, done after creation for optimal DB create performance
IF (@DataSizeMB > 32)
BEGIN
	SET @SqlStatement = @SqlStatement + '
	ALTER DATABASE [' + @DbName + '] MODIFY FILE ( NAME = N''' + @DbName + '_Data01'', SIZE = ' + (CONVERT(nvarchar(256),(@DataSizeMB/4))) + 'MB );
	ALTER DATABASE [' + @DbName + '] MODIFY FILE ( NAME = N''' + @DbName + '_Data02'', SIZE = ' + (CONVERT(nvarchar(256),(@DataSizeMB/4))) + 'MB );
	ALTER DATABASE [' + @DbName + '] MODIFY FILE ( NAME = N''' + @DbName + '_Data03'', SIZE = ' + (CONVERT(nvarchar(256),(@DataSizeMB/4))) + 'MB );
	ALTER DATABASE [' + @DbName + '] MODIFY FILE ( NAME = N''' + @DbName + '_Data04'', SIZE = ' + (CONVERT(nvarchar(256),(@DataSizeMB/4))) + 'MB );
	'
END

-- Expand Log file to desired size, done after creation for optimal DB create performance
IF (@LogSizeMB > 8)
BEGIN
	SET @SqlStatement = @SqlStatement + '
	ALTER DATABASE [' + @DbName + '] MODIFY FILE ( NAME = N''' + @DbName + '_Log'', SIZE = ' + (CONVERT(nvarchar(256),@LogSizeMB)) + 'MB );
	'
END


EXECUTE (@SqlStatement)

GO