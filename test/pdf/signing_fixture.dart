import 'dart:convert';
import 'dart:typed_data';

// ICP-Brasil AC Raiz histórica, usada apenas para exercitar parser/estrutura.
// A assinatura de integração gera seu próprio certificado e chave temporários.
Uint8List signingTestCertificate() => base64Decode(
      'MIIEuDCCA6CgAwIBAgIBBDANBgkqhkiG9w0BAQUFADCBtDELMAkGA1UEBhMCQlIx'
      'EzARBgNVBAoTCklDUC1CcmFzaWwxPTA7BgNVBAsTNEluc3RpdHV0byBOYWNpb25h'
      'bCBkZSBUZWNub2xvZ2lhIGRhIEluZm9ybWFjYW8gLSBJVEkxETAPBgNVBAcTCEJy'
      'YXNpbGlhMQswCQYDVQQIEwJERjExMC8GA1UEAxMoQXV0b3JpZGFkZSBDZXJ0aWZp'
      'Y2Fkb3JhIFJhaXogQnJhc2lsZWlyYTAeFw0wMTExMzAxMjU4MDBaFw0xMTExMzAy'
      'MzU5MDBaMIG0MQswCQYDVQQGEwJCUjETMBEGA1UEChMKSUNQLUJyYXNpbDE9MDsG'
      'A1UECxM0SW5zdGl0dXRvIE5hY2lvbmFsIGRlIFRlY25vbG9naWEgZGEgSW5mb3Jt'
      'YWNhbyAtIElUSTERMA8GA1UEBxMIQnJhc2lsaWExCzAJBgNVBAgTAkRGMTEwLwYD'
      'VQQDEyhBdXRvcmlkYWRlIENlcnRpZmljYWRvcmEgUmFpeiBCcmFzaWxlaXJhMIIB'
      'IjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwPMudwX/hvm+Uh2b/lQAcHVA'
      'isamaLkWdkwP9/S/tOKIgRrL6Oy+ZIGlOUdd6uYtk9Ma/3pUpgcfNAj0vYm5gsyj'
      'Qo9emsc+x6m4VWwk9iqMZSCK5EQkAq/Ut4n7KuLE1+gdftwdIgxfUsPt4CyNrY5'
      '0QV57KM2UT8x5rrmzEjr7TICGpSUAl2gVqe6xaii+bmYR1QrmWaBSAG59LrkrjrY'
      'tbRhFboUDe1DK+6T8s5L6k8c8okpbHpa9veMztDVC9sPJ60MWXh6anVKo1UcLcb'
      'URyEeNvZneVRKAAU6ouwdjDvwlsaKydFKwed0ToQ47bmUKgcm+wV3eTRk36UOnTw'
      'IDAQABo4HSMIHPME4GA1UdIARHMEUwQwYFYEwBAQAwOjA4BggrBgEFBQcCARYsaH'
      'R0cDovL2FjcmFpei5pY3BicmFzaWwuZ292LmJyL0RQQ2FjcmFpei5wZGYwPQYDVR'
      '0fBDYwNDAyoDCgLoYsaHR0cDovL2FjcmFpei5pY3BicmFzaWwuZ292LmJyL0xDUm'
      'FjcmFpei5jcmwwHQYDVR0OBBYEFIr68VeEERM1kEL6V0lUaQ2kxPA3MA8GA1UdEw'
      'EB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBBQUAA4IBAQAZA5'
      'c1U/hgIh6OcgLAfiJgFWpvmDZWqlV30/bHFpj8iBobJSm5uDpt7TirYh1Uxe3fQa'
      'GlYjJe+9zd+izPRbBqXPVQA34EXcwk4qpWuf1hHriWfdrx8AcqSqr6CuQFwSr75F'
      'osSzlwDADa70mT7wZjAmQhnZx2xJ6wfWlT9VQfS//JYeIc7Fue2JNLd00UOSMMai'
      'K/t79enKNHEA2fupH3vEigf5Eh4bVAN5VohrTm6MY53x7XQZZr1ME7a55lFEnSeT'
      '0umlOAjR2mAbvSM5X5oSZNrmetdzyTj2flCM8CC7MLab0kkdngRIlUBGHF1/S5nm'
      'PbK+9A46sd33oqK8n8',
    );

// Certificado P-256 efemero usado somente para exercitar metadados e a
// normalizacao ECDSA dos provedores. Nao acompanha chave privada.
Uint8List ecdsaSigningTestCertificate() => base64Decode(
      'MIIBkTCCATegAwIBAgIUCccDUM+2A0k/eKJ/lXscNYJIrvwwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTRUNEU0EgUHJvdmlkZXIgVGVzdDAeFw0yNjA4MjMyMzMzMDJaFw0zNjA4MjAyMzMzMDJaMB4xHDAaBgNVBAMME0VDRFNBIFByb3ZpZGVyIFRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATmwSH00QAgRFsn3JVrQZKbm/zYUJjZk2vlVs3zdsqbOgyIDiLEZY7LZcAENcxTrHgOo/7emWEBb5nFrcdnRWfqo1MwUTAdBgNVHQ4EFgQUlH8alWqtI0sCxV0yrHqoRC90MxIwHwYDVR0jBBgwFoAUlH8alWqtI0sCxV0yrHqoRC90MxIwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA+x5rZngBFbgvv59NU2DVdlStuleHu/lL+nl1gppq4IECIBJkYJfsyWzFUXwWt/9tVn4ItgFXD+gcQEMCzhCAVI8I',
    );
