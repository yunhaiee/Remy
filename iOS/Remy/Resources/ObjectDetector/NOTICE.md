EfficientDet-Lite0 int8, Google MediaPipe object detection model.
Source: https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/int8/1/efficientdet_lite0.tflite
SHA-256: 0720bf247bd76e6594ea28fa9c6f7c5242be774818997dbbeffc4da460c723bb
Guide: https://developers.google.com/edge/mediapipe/solutions/vision/object_detector
License: Apache-2.0 (https://www.apache.org/licenses/LICENSE-2.0).
COCO 80-category detector. Categories and boxes are predictions, not ingredient identity, temperature, or a safety guarantee.

The optional YOLOX-M detector uses Megvii-BaseDetection/YOLOX (Apache-2.0),
source revision `6ddff4824372906469a7fae2dc3206c7aa4bbaee` and official
`0.1.1rc0/yolox_m.pth` checkpoint. `scripts/prepare_coreml_detector.py` pins both
artifacts and converts the public weights to a float16 Core ML program locally.
Input: 640 × 640 BGR, unnormalized 0–255 values, top-left letterbox padded with 114.
Output uses COCO's 80 categories, confidence 0.5, class-wise NMS 0.45, at most 8 boxes.
Model binaries are excluded from Git. The converted model retains the source license;
see `YOLOX-LICENSE.txt` in this folder.
