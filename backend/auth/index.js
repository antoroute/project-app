const express = require('express');
const app = express();
app.get('/api/health', (req, res) => res.send('Messaging OK'));
app.listen(3001);