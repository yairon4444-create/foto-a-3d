import 'package:flutter_test/flutter_test.dart';

import 'package:proyecto3d/main.dart';

void main() {
  testWidgets('renders photo to 3D home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PhotoTo3DApp());

    expect(find.text('Foto a 3D'), findsOneWidget);
    expect(find.text('Elegir imagen'), findsOneWidget);
    expect(find.text('Enviar a convertir'), findsOneWidget);
    expect(find.text('Tu imagen aparecera aqui'), findsOneWidget);
  });
}
