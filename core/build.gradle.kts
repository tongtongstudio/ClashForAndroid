import com.github.kr328.golang.GolangBuildTask
import com.github.kr328.golang.GolangPlugin
import java.io.FileOutputStream
import java.net.URL
import java.time.Duration

plugins {
    kotlin("android")
    id("com.android.library")
    id("kotlinx-serialization")
    id("golang-android")
}

val geoipDatabaseUrl =
    "https://github.com/Dreamacro/maxmind-geoip/releases/latest/download/Country.mmdb"
val geoipInvalidate = Duration.ofDays(7)!!
val geoipOutput = buildDir.resolve("intermediates/golang_blob")
val golangSource = file("src/main/golang/native")

golang {
    sourceSets {
        create("foss") {
            tags.set(listOf("foss"))
            srcDir.set(file("src/foss/golang"))
        }
        create("premium") {
            tags.set(listOf("premium", "without_gvisor", "without_system"))
            srcDir.set(file("src/premium/golang"))
        }
        all {
            fileName.set("libclash.so")
            packageName.set("cfa/native")
        }
    }
}

android {
    productFlavors {
        all {
            externalNativeBuild {
                cmake {
                    arguments("-DGO_SOURCE:STRING=${golangSource}")
                    arguments("-DGO_OUTPUT:STRING=${GolangPlugin.outputDirOf(project, null, null)}")
                    arguments("-DFLAVOR_NAME:STRING=$name")
                }
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
}

dependencies {
    implementation(project(":common"))

    implementation(libs.androidx.core)
    implementation(libs.kotlin.coroutine)
    implementation(libs.kotlin.serialization.json)
}

afterEvaluate {
    val go120Home = providers.gradleProperty("go120Home").orNull ?: System.getenv("GO120_HOME")

    tasks.withType(GolangBuildTask::class.java).forEach {
        it.inputs.dir(golangSource)

        if (it.name.contains("Premium")) {
            // Clash.Meta(2023) 依赖的 quic-go 不支持 Go 1.21+，premium 变体固定使用 Go 1.20
            if (go120Home.isNullOrBlank()) {
                it.doFirst {
                    throw GradleException("premium 变体需要 Go 1.20 工具链，请通过 -Pgo120Home=<go1.20 目录> 指定")
                }
            } else {
                it.environment("PATH", "$go120Home\\bin;${System.getenv("PATH")}")
                it.environment("GOROOT", go120Home)
                it.executable = "$go120Home/bin/go.exe"
            }
            it.environment("GOFLAGS", "")
        } else {
            // Go 1.23+ 会拦截旧版 x/net 对 syscall 的 linkname，插件本身不传该参数，这里补上
            it.environment("GOFLAGS", "-ldflags=-checklinkname=0")
        }
    }
}

task("downloadGeoipDatabase") {
    val databaseFile = geoipOutput.resolve("Country.mmdb")
    val moduleFile = geoipOutput.resolve("go.mod")
    val sourceFile = geoipOutput.resolve("blob.go")

    val moduleContent = """
        module "cfa/blob"
    """.trimIndent()

    val sourceContent = """
        package blob
        
        import _ "embed"
        
        //go:embed Country.mmdb
        var GeoipDatabase []byte
    """.trimIndent()

    outputs.dir(geoipOutput)

    onlyIf {
        System.currentTimeMillis() - databaseFile.lastModified() > geoipInvalidate.toMillis()
    }

    doLast {
        geoipOutput.mkdirs()

        moduleFile.writeText(moduleContent)
        sourceFile.writeText(sourceContent)

        URL(geoipDatabaseUrl).openConnection().getInputStream().use { input ->
            FileOutputStream(databaseFile).use { output ->
                input.copyTo(output)
            }
        }
    }
}

afterEvaluate {
    val downloadTask = tasks["downloadGeoipDatabase"]

    tasks.forEach {
        if (it.name.startsWith("externalGolangBuild")) {
            it.dependsOn(downloadTask)
        }
    }
}