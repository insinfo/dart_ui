# POC-05 — COM e Direct2D

Cria uma `ID2D1Factory` em `d2d1.dll` usando `package:win32` para COM,
`GUID`, alocação de escopo e chamadas a `IUnknown`. O POC valida o contrato de
criação, `QueryInterface`, `AddRef` e `Release` com liberação explícita.

```powershell
dart run poc/poc_05_com_direct2d/bin/main.dart
```
