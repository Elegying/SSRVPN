import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// Resume an interrupted selection only when the user opens the picker again.
/// The shared settings page still requires preview confirmation before saving.
Future<XFile?> pickAndroidBackgroundImage() async {
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) {
    picker.useAndroidPhotoPicker = true;
  }
  final lost = await picker.getLostData();
  if (lost.exception != null) throw lost.exception!;
  if (lost.files?.isNotEmpty ?? false) return lost.files!.first;
  return picker.getImageFromSource(source: ImageSource.gallery);
}
