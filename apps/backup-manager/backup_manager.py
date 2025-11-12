import os, subprocess, json, time
from datetime import datetime
PGUSER=os.getenv('PGUSER','forensic_user'); PGPASSWORD=os.getenv('PGPASSWORD','Forensic123!'); PGDB=os.getenv('PGDB','ffactory_core')
BACKUP_DIR=os.getenv('BACKUP_DIR','/backups'); os.makedirs(BACKUP_DIR,exist_ok=True)
def run():
    ts=datetime.now().strftime("%Y%m%d_%H%M%S")
    dump=os.path.join(BACKUP_DIR,f"postgres_{ts}.sql")
    env=os.environ.copy(); env['PGPASSWORD']=PGPASSWORD
    subprocess.run(['pg_dump','-U',PGUSER,'-h','db','-d',PGDB,'-f',dump],check=True,env=env)
    meta=os.path.join(BACKUP_DIR,'settings_snapshot.json'); open(meta,'w').write(json.dumps(dict(os.environ),indent=2))
    arc=os.path.join(BACKUP_DIR,f"ffactory_backup_{ts}.tar.gz")
    subprocess.run(['tar','-czf',arc,'-C',BACKUP_DIR,os.path.basename(dump),os.path.basename(meta)],check=True)
    os.remove(dump)
if __name__=="__main__":
    time.sleep(5)
    try: run(); print("Backup OK")
    except Exception as e: print("Backup failed:",e)
