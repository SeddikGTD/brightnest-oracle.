const express = require('express');
const app = express();
const path = require('path');

// إعداد المنفذ (Port) بشكل ديناميكي ليعمل على Railway
const PORT = process.env.PORT || 3000;

// لخدمة الملفات الثابتة (مثل index.html, style.css, script.js)
app.use(express.static(__dirname));

// مسار الصفحة الرئيسية
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// تشغيل السيرفر
app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server is running on port ${PORT}`);
});

// إضافة مراقبة للأخطاء غير المعالجة لمنع توقف السيرفر
process.on('uncaughtException', (err) => {
    console.error('There was an uncaught error', err);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
});
