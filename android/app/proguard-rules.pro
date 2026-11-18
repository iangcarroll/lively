# kotlinx.serialization keeps its generated serializers via its own rules.
# OkHttp and Play Billing ship consumer rules.

# Play In-App Review refers to a compile-time annotation that Play services
# no longer ships; nothing uses it at run time.
-dontwarn com.google.android.gms.common.annotation.NoNullnessRewrite
