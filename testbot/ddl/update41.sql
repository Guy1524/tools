USE winetestbot;

ALTER TABLE Tasks
  ADD Missions VARCHAR(256) NULL
      AFTER Timeout;

UPDATE Tasks, VMs
  SET Tasks.Missions = 'build'
  WHERE Tasks.Missions is NULL AND Tasks.VMName = VMs.Name AND VMs.Type = 'build';

UPDATE Tasks, VMs
  SET Tasks.Missions = 'exe32'
  WHERE Tasks.Missions is NULL AND Tasks.VMName = VMs.Name AND VMs.Type = 'win32';

UPDATE Tasks, VMs
  SET Tasks.Missions = 'exe32|exe64'
  WHERE Tasks.Missions is NULL AND Tasks.VMName = VMs.Name AND VMs.Type = 'win64';

UPDATE Tasks, VMs
  SET Tasks.Missions = 'win32:wow64'
  WHERE Tasks.Missions is NULL AND Tasks.VMName = VMs.Name AND VMs.Type = 'wine';

ALTER TABLE Tasks
  MODIFY Missions VARCHAR(256) NOT NULL;


ALTER TABLE VMs
  ADD Missions VARCHAR(256) NULL
      AFTER Role;

UPDATE VMs
  SET Missions = 'build'
  WHERE Missions is NULL AND Type = 'build';

UPDATE VMs
  SET Missions = 'exe32'
  WHERE Missions is NULL AND Type = 'win32';

UPDATE VMs
  SET Missions = 'exe32|exe64'
  WHERE Missions is NULL AND Type = 'win64';

UPDATE VMs
  SET Missions = 'win32|wow64'
  WHERE Missions is NULL AND Type = 'wine';

ALTER TABLE VMs
  MODIFY Missions VARCHAR(256) NOT NULL;
