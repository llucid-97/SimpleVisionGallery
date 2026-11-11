# Target audience: agents. Builds fresh source; owns one Simulator only while actively running.
from pathlib import Path
import os, subprocess, sys, time, json, signal
here=Path(__file__).resolve().parent
fixture=here/'fixture'; derived=here/'DerivedData'; sim=os.environ['GALLERY_SIMULATOR_UDID']
bundle=os.environ['GALLERY_GENERATED_TEST_BUNDLE']
booted=False
permission_job=None
permission_log=None

def run(args, timeout=120, **kw): return subprocess.run(args,check=True,text=True,capture_output=True,timeout=timeout,**kw)
def stop(sig, frame): raise SystemExit(128+sig)
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
# Own the simulator only for this bounded run so cleanup happens after failures.
try:
 run(['python3',str(here/'prepare.py')])
 with (here/'photos-native-build.log').open('w') as log:
  subprocess.run(['xcodegen','generate','--spec','project.yml'],cwd=fixture,check=True,stdout=log,stderr=subprocess.STDOUT,timeout=60)
  subprocess.run(['xcodebuild','-project',str(fixture/'SimpleVisionGallery.xcodeproj'),'-scheme','SimpleVisionGallery','-destination','generic/platform=visionOS Simulator','-derivedDataPath',str(derived),'-jobs','4','PRODUCT_BUNDLE_IDENTIFIER='+bundle,'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','CODE_SIGN_ENTITLEMENTS='+str(here/'existing-test.entitlements'),'DEVELOPMENT_TEAM='+os.environ['GALLERY_SIMULATOR_TEST_TEAM'],'build'],check=True,stdout=log,stderr=subprocess.STDOUT,timeout=900)
 print('BUILD_PASS',flush=True)
 if sim in run(['xcrun','simctl','list','devices','booted']).stdout: raise RuntimeError('owned test simulator already booted; refusing to claim')
 run(['xcrun','simctl','boot',sim]); booted=True
 run(['xcrun','simctl','bootstatus',sim,'-b'],timeout=300)
 run(['xcrun','simctl','install',sim,str(derived/'Build/Products/Debug-xrsimulator/SimpleVisionGallery.app')])
 started=time.time();run(['xcrun','simctl','launch',sim,bundle])
 container=Path(run(['xcrun','simctl','get_app_container',sim,bundle,'data']).stdout.strip()); docs=container/'Documents'; result=docs/'auto-result.json'; marker=docs/'auto-build.txt'; last=None; last_seed=None; deadline=time.monotonic()+360
 # Watch fixed fixture progress until a result or deadline is reached.
 while time.monotonic()<deadline:
  seed=docs/'seed-progress.txt'
  if seed.exists() and seed.stat().st_mtime >= started:
   value=seed.read_text()
   if value != last_seed: print('SEED '+value,flush=True);last_seed=value
  phase=docs/'auto-progress.txt'
  if phase.exists():
   value=phase.read_text()
   if value!=last: print('STEP '+value,flush=True);last=value
  if result.exists() and result.stat().st_mtime>=started:
   payload=json.loads(result.read_text());assert payload['kind']=='core-contracts-generated-v1' and marker.read_text()==payload['kind']
   (here/'photos-native-result.json').write_text(json.dumps(payload,indent=2)+'\n');print(json.dumps(payload),flush=True)
   if not payload['passed']: raise RuntimeError('fixture check failed: '+payload['failed_step'])
   break
  time.sleep(.25)
 else: raise TimeoutError('fixture deadline')
finally:
 if permission_job is not None:
  if permission_job.poll() is None:
   import os
   os.killpg(permission_job.pid, signal.SIGTERM)
   try: permission_job.wait(timeout=20)
   except subprocess.TimeoutExpired: os.killpg(permission_job.pid, signal.SIGKILL); permission_job.wait(timeout=10)
  if permission_log is not None: permission_log.close()
 if booted:
  p=subprocess.run(['xcrun','simctl','shutdown',sim],capture_output=True,text=True,timeout=60)
  print('OWNED_SIMULATOR_SHUTDOWN '+str(p.returncode),flush=True)
