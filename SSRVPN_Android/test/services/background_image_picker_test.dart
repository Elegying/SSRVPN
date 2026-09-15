import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:ssrvpn_android/services/background_image_picker.dart';

class _Picker extends ImagePickerPlatform {
  LostDataResponse recovered = LostDataResponse.empty();
  XFile? selection;
  int opens = 0;
  @override
  Future<LostDataResponse> getLostData() async => recovered;
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    expect(source, ImageSource.gallery);
    opens++;
    return selection;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ImagePickerPlatform original;
  late _Picker picker;
  setUp(() {
    original = ImagePickerPlatform.instance;
    picker = _Picker();
    ImagePickerPlatform.instance = picker;
  });
  tearDown(() => ImagePickerPlatform.instance = original);
  test('gallery selection and cancellation preserve the picker result',
      () async {
    expect(await pickAndroidBackgroundImage(), isNull);
    picker.selection = XFile('/cache/photo.png');
    expect((await pickAndroidBackgroundImage())!.path, '/cache/photo.png');
    expect(picker.opens, 2);
  });
  test(
      'interrupted selection returns for preview without opening another picker',
      () async {
    picker.recovered = LostDataResponse(files: [XFile('/cache/recovered.png')]);
    expect((await pickAndroidBackgroundImage())!.path, '/cache/recovered.png');
    expect(picker.opens, 0);
  });
  test('recovery errors reach the existing non-destructive import failure flow',
      () async {
    picker.recovered =
        LostDataResponse(exception: PlatformException(code: 'lost'));
    await expectLater(
        pickAndroidBackgroundImage(), throwsA(isA<PlatformException>()));
    expect(picker.opens, 0);
  });
}
