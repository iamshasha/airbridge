# kotlinx.serialization keeps generated serializers.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class app.airbridge.core.** { *** Companion; *** serializer(...); }
-keep,includedescriptorclasses class app.airbridge.core.**$$serializer { *; }
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
