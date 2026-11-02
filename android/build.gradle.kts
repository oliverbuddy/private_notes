import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// file_picker 8.3.7 的 android/build.gradle 里硬编码了 `compileSdk 34`，
// 而它的传递依赖 flutter_plugin_android_lifecycle 2.0.35 的 AAR 元数据要求
// 使用方 compileSdk >= 36，否则 checkReleaseAarMetadata 直接让构建失败。
// 这里统一把各 Android 插件模块的 compileSdk 抬到 36（Flutter 自己也是 36），
// 避免去 fork / 修改 pub-cache 里的第三方插件源码。
//
// 注意：这段必须注册在下面的 evaluationDependsOn(":app") 之前 —— 那个调用会提前
// 触发子工程评估，之后再调 afterEvaluate 会报 "project is already evaluated"。
subprojects {
    if (state.executed) {
        extensions.findByType(LibraryExtension::class.java)?.compileSdk = 36
    } else {
        afterEvaluate {
            extensions.findByType(LibraryExtension::class.java)?.compileSdk = 36
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
