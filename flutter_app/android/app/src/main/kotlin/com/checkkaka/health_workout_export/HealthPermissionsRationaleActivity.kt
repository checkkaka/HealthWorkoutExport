package com.checkkaka.health_workout_export

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** The Health Connect permission screen opens this explanation; no data is read here. */
class HealthPermissionsRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "健康数据使用说明"
        val padding = (20 * resources.displayMetrics.density).toInt()
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
        }
        content.addView(TextView(this).apply {
            textSize = 18f
            text = "HealthWorkoutExport 读取您授权的训练记录，以及可选的心率、距离、速度、功率、踏频、步数与活动能量，用于训练列表、FIT/JSON 导出和您选择的同步。应用不会写入或删除 Health Connect 中的健康数据。\n\n" +
                "路线数据需要额外的逐训练同意。拒绝某项可选权限时，应用会保留其余可用数据并标明缺失。读取较早记录可能需要历史记录权限；应用不申请后台健康数据读取权限。\n\n" +
                "导出文件可能包含健康数据和精确路线。您选择分享或同步后，文件会提供给相应接收方，例如 Strava。启用需要天气数据的虚拟功率功能时，天气请求可能携带轨迹位置和时间。请在操作前检查应用中的相关说明。\n\n" +
                "您可以随时在 Health Connect 设置中撤销权限。撤销权限不会自动删除此前生成、保存、分享或上传的文件；这些文件需要在相应位置单独管理。"
        })
        content.addView(Button(this).apply { text = "返回"; setOnClickListener { finish() } })
        setContentView(ScrollView(this).apply { addView(content) })
    }
}
