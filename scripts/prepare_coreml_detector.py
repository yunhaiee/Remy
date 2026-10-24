#!/usr/bin/env python3
"""Prepare the optional public YOLOX-M Core ML detector on macOS. No user data is read or uploaded.

Use a Python 3.12 environment with torch==2.7.0, torchvision==0.22.0,
coremltools==9.0, loguru, opencv-python, tabulate, tqdm, psutil and thop.
The lightweight EfficientDet fallback is prepared by download_detector.py.
"""
import hashlib,json,subprocess,sys,tarfile,urllib.request
from pathlib import Path

root=Path(__file__).resolve().parents[1]
cache=root/'.build-cache/coreml-detector';cache.mkdir(parents=True,exist_ok=True)
revision='6ddff4824372906469a7fae2dc3206c7aa4bbaee'
source_url=f'https://codeload.github.com/Megvii-BaseDetection/YOLOX/tar.gz/{revision}'
weights_url='https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_m.pth'

def fetch(url,path,digest):
    def valid():
        return path.exists() and hashlib.file_digest(path.open('rb'),'sha256').hexdigest()==digest
    if valid():return
    temp=path.with_suffix('.partial')
    with urllib.request.urlopen(url,timeout=120) as response,temp.open('wb') as output:
        while chunk:=response.read(1024*1024):output.write(chunk)
    if hashlib.file_digest(temp.open('rb'),'sha256').hexdigest()!=digest:
        raise RuntimeError('Public detector integrity check failed; existing model preserved.')
    temp.replace(path)

fetch(source_url,cache/'source.tar.gz','103b59b2d679f2ab829e7f7bf348242c400efa925a4adb262cbf3dd375c4ec0c')
fetch(weights_url,cache/'yolox_m.pth','60076992b32da82951c90cfa7bd6ab70eba9eda243e08b940a396f60ac2d19b6')
source=cache/f'YOLOX-{revision}'
if not source.exists():
    with tarfile.open(cache/'source.tar.gz') as archive:archive.extractall(cache,filter='data')
sys.path.insert(0,str(source))
import torch
import coremltools as ct
from yolox.exp import get_exp
if torch.__version__.split('+')[0]!='2.7.0' or ct.__version__!='9.0':
    raise RuntimeError('Use pinned torch 2.7.0 and coremltools 9.0 to reproduce the evaluated conversion.')
torch.set_num_threads(4)
exp=get_exp(str(source/'exps/default/yolox_m.py'),None)
model=exp.get_model().eval()
model.load_state_dict(torch.load(cache/'yolox_m.pth',map_location='cpu',weights_only=True)['model'])
model.head.decode_in_inference=True
sample=torch.zeros(1,3,640,640)
with torch.no_grad():
    model(sample)
    traced=torch.jit.trace(model,sample,check_trace=False)
converted=ct.convert(traced,convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,
    inputs=[ct.ImageType(name='image',shape=sample.shape,color_layout=ct.colorlayout.BGR,scale=1.0)],
    outputs=[ct.TensorType(name='detections')],compute_precision=ct.precision.FLOAT16)
converted.short_description='YOLOX-M COCO detector; official Apache-2.0 Megvii weights.'
converted.license='Apache-2.0'
package=cache/'yolox_m.mlpackage';converted.save(str(package))
resource=root/'iOS/Remy/Resources/ObjectDetector'
subprocess.run(['xcrun','coremlcompiler','compile',str(package),str(resource)],check=True)
print('Public Core ML detector prepared locally. Compiled weights remain ignored by Git.')
