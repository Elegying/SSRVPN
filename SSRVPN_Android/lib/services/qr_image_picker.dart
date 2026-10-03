import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// QR selection uses the system picker; no broad photo-library permission.
Future<XFile?> pickAndroidQrImage() async {
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
  return picker.getImageFromSource(source: ImageSource.gallery);
}
