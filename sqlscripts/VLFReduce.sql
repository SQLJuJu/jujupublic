-- Created by SQLJuJu 2025-04-28  with the help of ChatGPT and lots and lots of manual fixes.
--  Chances are you have more than 5,000 databases and they're all 10 terabytes each. This code is a gift to the world, I offer no warranty. 
--  Review it as you would review a first-month intern's code. If you destroy production, you should have tested. Don't sue me. 

-- Purpose: Shrink log files to reduce VLF count. 
-- Problem solved: High VLF count can cause delays during database startup, maintenance, backups, more. "High" is a relative term, could be 500 or 50,000.
--  I prefer 500 or less for a 2TB database. 
--  Parameters are below. Adjust them to suit your needs. 



-- ========== Parameters ==========
DECLARE @ShrinkToMB INT = 500;          -- Size to shrink to (MB)
DECLARE @ShrinkByMB INT = 5000;         -- By how many MB to shrink each time (keep low for a busy server / concurrency)
DECLARE @GrowIncrementMB INT = 8192;    -- Size to grow each step (MB) - 8192 = 8GB  (keep low for a busy server / concurrency)
DECLARE @ExecuteCommands CHAR(1) = 'N'; -- 'Y' = execute commands, else just print
DECLARE @VLFThreshold INT = 1000;       -- Aim for less than this number of VLFs. Modern systems prefer less than 1,000 or so for < 1TB. 
-- =================================

-- Prep temp tables
IF OBJECT_ID('tempdb..#VLFCounts') IS NOT NULL DROP TABLE #VLFCounts;
IF OBJECT_ID('tempdb..#Actions') IS NOT NULL DROP TABLE #Actions;

CREATE TABLE #VLFCounts (
    DatabaseName SYSNAME,
    FileId INT,
    FileName NVARCHAR(256),
    VLFCount INT,
    SizeMB BIGINT
);

CREATE TABLE #Actions (
	id INT identity,
    Command NVARCHAR(MAX)
);

-- Variables
DECLARE @DatabaseName SYSNAME;
DECLARE @SQL NVARCHAR(MAX);

-- Cursor over all databases
DECLARE db_cursor CURSOR FOR
SELECT name
FROM sys.databases
WHERE state_desc = 'ONLINE'
  AND name NOT IN ('tempdb');

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Collect VLF info for this database
    SET @SQL = '
    USE ' + QUOTENAME(@DatabaseName) + ';
    INSERT INTO #VLFCounts (DatabaseName, FileId, FileName, VLFCount, SizeMB)
	
SELECT 
    DB_NAME() AS DatabaseName,
    l.file_id,
    mf.name AS FileName,
    COUNT(*) AS VLFCount,
    SUM((convert(bigint,l.vlf_size_mb)))  AS SizeMB
FROM sys.dm_db_log_info(DB_ID()) l
INNER JOIN sys.database_files mf
    ON l.file_id = mf.file_id
WHERE mf.type_desc = ''LOG''
GROUP BY l.file_id, mf.name;
    ';
	PRINT @SQL
    EXEC sp_executesql @SQL;

    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT * FROM #VLFCounts 

--Delete this line while reviewing.  I'm serious, be careful in production.
SELECT 'YOU DIDN''T REVIEW THE CODE DID YOU?' as TskTskTsk

-- Now process those with too many VLFs
DECLARE @DB SYSNAME, @File NVARCHAR(256), @SizeMB BIGINT, @HalfSizeMB BIGINT;
DECLARE ActionCursor CURSOR FOR
SELECT DatabaseName, FileName, SizeMB
FROM #VLFCounts
WHERE VLFCount > @VLFThreshold;

OPEN ActionCursor;
FETCH NEXT FROM ActionCursor INTO @DB, @File, @SizeMB;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Calculate half of the original size
    SET @HalfSizeMB = @SizeMB / 2;

    -- Step 1: Shrink in steps to target @ShrinkToMB
    DECLARE @CurrentSizeMB BIGINT = @SizeMB;
    WHILE @CurrentSizeMB > @ShrinkToMB
    BEGIN
        SET @CurrentSizeMB = CASE WHEN @CurrentSizeMB - @ShrinkByMB < @ShrinkToMB THEN @ShrinkToMB ELSE @CurrentSizeMB - @ShrinkByMB END;

        DECLARE @ShrinkCommand NVARCHAR(MAX) = 'USE [' + @DB + ']; DBCC SHRINKFILE ([' + @File + '], ' + CAST(@CurrentSizeMB AS VARCHAR(10)) + ');';
        INSERT INTO #Actions (Command) VALUES (@ShrinkCommand);

        IF @ExecuteCommands = 'Y'
            EXEC sp_executesql @ShrinkCommand;
        
        IF @CurrentSizeMB = @ShrinkToMB BREAK;
    END

    -- Step 2: Grow back in increments
    DECLARE @GrowTargetMB BIGINT = @ShrinkToMB;
    WHILE @GrowTargetMB < @HalfSizeMB
    BEGIN
        SET @GrowTargetMB = @GrowTargetMB + @GrowIncrementMB;
        IF @GrowTargetMB > @HalfSizeMB SET @GrowTargetMB = @HalfSizeMB;

        DECLARE @GrowCommand NVARCHAR(MAX) = 'USE [' + @DB + ']; ALTER DATABASE [' + @DB + '] MODIFY FILE (NAME = N''' + @File + ''', SIZE = ' + CAST(@GrowTargetMB AS VARCHAR(10)) + 'MB);';
        INSERT INTO #Actions (Command) VALUES (@GrowCommand);

        IF @ExecuteCommands = 'Y'
            EXEC sp_executesql @GrowCommand;
        
        IF @GrowTargetMB = @HalfSizeMB BREAK;
    END

    FETCH NEXT FROM ActionCursor INTO @DB, @File, @SizeMB;
END

CLOSE ActionCursor;
DEALLOCATE ActionCursor;

-- Final Output: Always print all generated commands
SELECT id, Command
FROM #Actions
ORDER BY id;


