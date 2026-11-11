# Target audience: agents. Copy maintained fixture inputs into ignored scratch before builds.
from pathlib import Path
import argparse, os, plistlib, shutil, subprocess, sys, tempfile
parser=argparse.ArgumentParser()
parser.add_argument("--photos-system-prompt", action="store_true", help="also run the Photos transfer that requires a human to approve the generated one-photo system prompt")
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
source=root/'tests/native'
base=root/'.codex-tests/core-runtime'
required=['GALLERY_SIMULATOR_UDID','GALLERY_GENERATED_TEST_BUNDLE','GALLERY_SIMULATOR_TEST_TEAM']
missing=[name for name in required if not os.environ.get(name)]
if missing: raise SystemExit('Set required environment variables: '+', '.join(missing))
if os.environ['GALLERY_GENERATED_TEST_BUNDLE'] in {'com.llucid.simplevisiongallery','meta.xla.simple-vision-tools'}:
 raise SystemExit('Use a dedicated generated-data-only test bundle')
base.mkdir(parents=True,exist_ok=True)
scratch=Path(tempfile.mkdtemp(prefix='run-',dir=base))
shutil.copytree(source,scratch,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
print('Evidence workspace: '+str(scratch),flush=True)
team=os.environ['GALLERY_SIMULATOR_TEST_TEAM']; bundle=os.environ['GALLERY_GENERATED_TEST_BUNDLE']
with (scratch/'existing-test.entitlements').open('wb') as f: plistlib.dump({'application-identifier':team+'.'+bundle,'com.apple.developer.team-identifier':team,'get-task-allow':True,'keychain-access-groups':[team+'.'+bundle]},f)
env=os.environ.copy()
for name in ('GALLERY_TRANSFER_PROOF','GALLERY_PHOTOS_ONLY','GALLERY_SKIP_PHOTOS','GALLERY_DIAGNOSTIC_SMALL'):
 env.pop(name,None)
env.update(GALLERY_REQUIRE_PHOTOS_AUTH='1', GALLERY_VIDEO_PROOF='1', GALLERY_PROFILE_PUBLISH='1', GALLERY_FIXTURE_SOURCE=str(root), GALLERY_FIXTURE_REVISION=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip())
if args.photos_system_prompt: env['GALLERY_TRANSFER_PROOF']='1'
print('Scope: generated functional transitions and retained-prefetch timings; Photos system prompt '+('included (requires approval)' if args.photos_system_prompt else 'NOT tested'),flush=True)
for runner in ['run_existing_photos.py','run_functional.py']:
 print('RUN '+runner,flush=True)
 subprocess.run([sys.executable,str(scratch/runner)],cwd=root,env=env,check=True)
 if runner == 'run_existing_photos.py':
  subprocess.run([sys.executable,str(scratch/'validate_timing.py'),str(scratch/'photos-native-result.json')],check=True)
 snapshot=scratch/'source-snapshot.json'
 if snapshot.exists(): shutil.copy(snapshot,scratch/('source-'+runner+'.json'))
