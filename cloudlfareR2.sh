#!/bin/bash

# 定义插件物理路径
PLUGIN_DIR="/root/services/typecho/data/plugins/CloudflareR2"

# 1. 强制清理重建
rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"

# 2. 写入 Plugin.php (采用传统无命名空间写法，确保 Typecho 扫描器秒识别)
cat << 'EOF' > "$PLUGIN_DIR/Plugin.php"
<?php
/**
 * Cloudflare R2
 * * @package CloudflareR2
 * @author yuyehd
 * @version 1.5.0
 * @link https://cloudflare.com
 */

class CloudflareR2_Plugin implements Typecho_Plugin_Interface
{
    public static function activate()
    {
        Typecho_Plugin::factory('Widget_Upload')->uploadHandle = array('CloudflareR2_Plugin', 'uploadHandle');
        Typecho_Plugin::factory('Widget_Upload')->modifyHandle = array('CloudflareR2_Plugin', 'modifyHandle');
        Typecho_Plugin::factory('Widget_Upload')->deleteHandle = array('CloudflareR2_Plugin', 'deleteHandle');
        Typecho_Plugin::factory('Widget_Upload')->attachmentHandle = array('CloudflareR2_Plugin', 'attachmentHandle');
        Typecho_Plugin::factory('Widget_Upload')->attachmentDataHandle = array('CloudflareR2_Plugin', 'attachmentDataHandle');
    }

    public static function deactivate() {}

    public static function config(Typecho_Widget_Helper_Form $form)
    {
        $bucket = new Typecho_Widget_Helper_Form_Element_Text('bucket', NULL, NULL, '存储桶名称 (Bucket)', 'Cloudflare R2 Bucket Name');
        $form->addInput($bucket->addRule('required', '必填'));

        $accId = new Typecho_Widget_Helper_Form_Element_Text('access_key_id', NULL, NULL, 'Access Key ID', 'R2 API Access Key ID');
        $form->addInput($accId->addRule('required', '必填'));

        $secKey = new Typecho_Widget_Helper_Form_Element_Password('secret_access_key', NULL, NULL, 'Secret Access Key', 'R2 API Secret Key');
        $form->addInput($secKey->addRule('required', '必填'));

        $ep = new Typecho_Widget_Helper_Form_Element_Text('endpoint', NULL, NULL, 'S3 Endpoint', '格式：https://<账户ID>.r2.cloudflarestorage.com');
        $form->addInput($ep->addRule('required', '必填'));

        $dom = new Typecho_Widget_Helper_Form_Element_Text('domain', NULL, NULL, '自定义访问域名', '格式：https://img.yourdomain.com');
        $form->addInput($dom->addRule('required', '必填'));

        $prefix = new Typecho_Widget_Helper_Form_Element_Text('path_prefix', NULL, 'uploads', '路径前缀', '默认 uploads');
        $form->addInput($prefix);
    }

    public static function personalConfig(Typecho_Widget_Helper_Form $form) {}

    public static function uploadHandle($file)
    {
        $options = Typecho_Widget::widget('Widget_Options')->plugin('CloudflareR2');
        $tmp = $file['file'] ?? $file['tmp_name'];
        $ext = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
        $path = '/' . trim($options->path_prefix, '/') . '/' . date('Y/m') . '/' . substr(md5_file($tmp), 8, 16) . '.' . $ext;
        
        self::request('PUT', $path, file_get_contents($tmp), $file['type']);
        return array('name' => $file['name'], 'path' => $path, 'size' => $file['size'], 'type' => $ext, 'mime' => $file['type']);
    }

    private static function request($method, $path, $body = '', $type = '')
    {
        $options = Typecho_Widget::widget('Widget_Options')->plugin('CloudflareR2');
        $host = parse_url($options->endpoint, PHP_URL_HOST);
        $dt = gmdate('Ymd\THis\Z'); $date = substr($dt, 0, 8); $ph = hash('sha256', $body);
        $uri = "/{$options->bucket}{$path}";
        $h = "host:{$host}\nx-amz-content-sha256:{$ph}\nx-amz-date:{$dt}\n";
        $sh = 'host;x-amz-content-sha256;x-amz-date';
        if ($type) { $h = "content-type:{$type}\n" . $h; $sh = 'content-type;' . $sh; }
        $sq = "{$method}\n{$uri}\n\n{$h}\n{$sh}\n{$ph}";
        $sts = "AWS4-HMAC-SHA256\n{$dt}\n{$date}/auto/s3/aws4_request\n" . hash('sha256', $sq);
        $kDate = hash_hmac('sha256', $date, 'AWS4' . $options->secret_access_key, true);
        $kRegion = hash_hmac('sha256', 'auto', $kDate, true);
        $kService = hash_hmac('sha256', 's3', $kRegion, true);
        $kSigning = hash_hmac('sha256', 'aws4_request', $kService, true);
        $sig = hash_hmac('sha256', $sts, $kSigning);
        $auth = "AWS4-HMAC-SHA256 Credential={$options->access_key_id}/{$date}/auto/s3/aws4_request,SignedHeaders={$sh},Signature={$sig}";
        $hd = array("Host: {$host}", "x-amz-content-sha256: {$ph}", "x-amz-date: {$dt}", "Authorization: {$auth}");
        if ($type) $hd[] = "Content-Type: {$type}";
        $ch = curl_init(rtrim($options->endpoint, '/') . $uri);
        curl_setopt_array($ch, array(CURLOPT_CUSTOMREQUEST => $method, CURLOPT_POSTFIELDS => $body, CURLOPT_HTTPHEADER => $hd, CURLOPT_RETURNTRANSFER => 1, CURLOPT_TIMEOUT => 30, CURLOPT_SSL_VERIFYPEER => 0));
        $res = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
        if ($code >= 400) throw new Typecho_Plugin_Exception('R2 Error: ' . $code);
        return $res;
    }

    public static function deleteHandle($content) {
        try { self::request('DELETE', $content['path']); return true; } catch (Exception $e) { return false; }
    }

    public static function attachmentHandle($content) {
        $options = Typecho_Widget::widget('Widget_Options')->plugin('CloudflareR2');
        return rtrim($options->domain, '/') . $content['attachment']->path;
    }

    public static function modifyHandle($content, $file) { return array(); }
    public static function attachmentDataHandle($content) { return ''; }
}
EOF

# 3. 设置权限
chown -R 33:33 "$PLUGIN_DIR"
chmod -R 755 "$PLUGIN_DIR"

echo "✅ 极简版部署完成！"
echo "👉 请进入 Typecho 后台，先[禁用]旧插件（如果有），再[激活] CloudflareR2 存储插件。"
