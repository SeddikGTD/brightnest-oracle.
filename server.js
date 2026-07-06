const express = require('express');
const path = require('path');
const app = express();

// إعداد المنفذ (Railway أو المنفذ الافتراضي 3000)
const PORT = process.env.PORT || 3000;

// لخدمة الملفات الثابتة (مثل index.html, style.css)
app.use(express.static(path.join(__dirname, '/')));

// مسار الصفحة الرئيسية
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// إضافة مراقبة للأخطاء غير المعالجة لمنع توقف السيرفر
process.on('uncaughtException', (err) => {
    console.error('There was an uncaught error', err);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
});

// تشغيل السيرفر
app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server is running on port ${PORT}`);
});
