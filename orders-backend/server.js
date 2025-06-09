require('dotenv').config();
const express = require('express');
const heicConvert = require('heic-convert');
const { Server } = require('socket.io');
const http    = require('http');
//const https = require('https');
const cors    = require('cors');
const db      = require('./db');
const util    = require('util');
const multer  = require('multer');
const sharp   = require('sharp');
const fs      = require('fs');
const path    = require('path');
const bcrypt = require('bcrypt');
const jwt    = require('jsonwebtoken');
const JWT_SECRET = process.env.JWT_SECRET ;

//const privateKey = fs.readFileSync('key.pem', 'utf8');
//const certificate = fs.readFileSync('cert.pem', 'utf8');

//const credentials = { key: privateKey, cert: certificate };

sharp.cache(false);
const dbQuery = util.promisify(db.query).bind(db);

const app = express();
const server = http.createServer(app);
const io   = new Server(server, {
  cors: { origin: '*' }
});
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));
app.use('/orders', authenticateToken);




io.on('connection', socket => {
  console.log(`Client connected: ${socket.id}`);
  socket.on('disconnect', () => {
    console.log(`Client disconnected: ${socket.id}`);
  });
});

// Multer config: allow up to 10 files under field "images"
const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, 'uploads/'),
  filename:    (req, file, cb) => {
    const unique = Date.now() + '-' + Math.round(Math.random()*1e9);
    cb(null, unique + path.extname(file.originalname));
  }
});

const upload = multer({
  storage,
  fileFilter: (_req, file, cb) => {
    // debug: log what you're actually seeing
    console.log('Incoming file:', file.originalname, '→', file.mimetype);

      // 1) images & evidence fields → only images
      if (file.fieldname === 'images' || file.fieldname === 'evidence' || file.fieldname === 'signature') {
     
        if (file.mimetype.startsWith('image/')) return cb(null, true);
        
           // 2) otherwise allow by common image extensions
    const ext = path.extname(file.originalname).toLowerCase();
    if (['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg','.heic','.heif'].includes(ext)) {
      return cb(null, true);
    }
        return cb(new Error('Only image files allowed'), false);
      }

     // 2) documents field → only PDFs
     if (file.fieldname === 'documents') {
      if (file.mimetype === 'application/pdf') return cb(null, true);
       return cb(new Error('Only PDF files allowed'), false);
     }


    // 3) reject everything else
    cb(new Error('Only image files are allowed'), false);
  }
});

function authenticateToken(req, res, next) {
  const auth = req.headers['authorization']?.split(' ');
  if (!auth || auth[0] !== 'Bearer') return res.sendStatus(401);

  const token = auth[1];
  jwt.verify(token, JWT_SECRET, (err, payload) => {
    if (err) return res.sendStatus(403);

    // payload is the decoded object  signed above
    req.userId   = payload.sub;
    req.username = payload.username;   

    next();
  });
}

 // helper to just return true/false if an order is in the db.
async function orderExists(orderId) {
  const rows = await dbQuery(
    'SELECT 1 FROM orders WHERE id = ?',
    [orderId]
  );

  
  return rows.length > 0;

}

//  middlewear if there isnt an order return
async function ensureOrderExists(req, res, next) {
  const { id } = req.params;

  if (!await orderExists(id)) {
   
    return res.status(404).json({ error: 'Order not found' });
  }
  next();
}





app.post('/login', express.json(), async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ error: 'Missing credentials' });
  }
  try {
    const [user] = await dbQuery(
      'SELECT id, password_hash, username FROM users WHERE username = ?',
      [username]
    );
    if (!user) return res.status(401).json({ error: 'Invalid user/pass' });

    const match = await bcrypt.compare(password, user.password_hash);
    if (!match) return res.status(401).json({ error: 'Invalid user/pass' });

    const token = jwt.sign(
      { 
        sub: user.id,
        username: user.username    
      },
      JWT_SECRET,
      { expiresIn: '7d' }
    );

    res.json({ token });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Server error' });
  }
});

// GET /orders with pagination, search, status filter, and aggregated images
app.get('/orders', (req, res) => {
  const page   = Math.max(parseInt(req.query.page) || 1, 1);
  const limit  = Math.min(Math.max(parseInt(req.query.limit) || 10, 1), 1000);
  const offset = (page - 1) * limit;
  const search = req.query.search ? `%${req.query.search.trim()}%` : '%';
  const status = req.query.status;

  // build WHERE conditions
  let whereClauses = [
    '(o.customerName LIKE ? OR o.jobId LIKE ? OR o.dateOrdered LIKE ? OR o.address LIKE ? OR o.phoneNumber LIKE ? OR o.emailAddress LIKE ? OR o.eta LIKE ?)'
  ];
  let params = [search, search, search,search, search, search, search];

  if (status && status !== 'all') {
    whereClauses.push('o.status = ?');
    params.push(status);
  }

  const where = 'WHERE ' + whereClauses.join(' AND ');

  // count total
  const countSql = `SELECT COUNT(*) AS total FROM orders o ${where}`;
  db.query(countSql, params, (err, cnt) => {
    if (err) return res.status(500).json({ error: err.message });
    const total = cnt[0].total;
    const totalPages = Math.ceil(total / limit);

    // fetch data
    const dataSql = `
      SELECT
        o.id,
        o.customerName,
        o.dateOrdered,
        o.jobId,
        o.status,
        o.urgent,
        o.address,
        o.phoneNumber,
        o.emailAddress,
        o.pickup,
        o.eta,
        COALESCE((
      SELECT JSON_ARRAYAGG(filename)
        FROM order_images
       WHERE order_id = o.id
    ), JSON_ARRAY()) AS images,
    COALESCE((
  SELECT JSON_ARRAYAGG(
    JSON_OBJECT(
      'filename',     filename,
      'originalname', originalname
    )
  )
    FROM order_documents
   WHERE order_id = o.id
), JSON_ARRAY()) AS documents
      FROM orders o
      ${where}
      ORDER BY
    (o.urgent = 1
     AND o.status NOT IN ('collected','delivered')
    ) DESC,
    o.id DESC
  LIMIT ? OFFSET ?
`;
    db.query(dataSql, [...params, limit, offset], (err, rows) => {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ data: rows, page, limit, total, totalPages });
    });
  });
});


// GET /orders/:id — return one order with its images
app.get('/orders/:id', ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  try {
    const [row] = await dbQuery(`
      SELECT
        o.id,
        o.customerName,
        o.dateOrdered,
        o.jobId,
        o.status,
        o.urgent,
        o.address,
         o.phoneNumber,
          o.emailAddress,
        o.pickup,
        o.eta,
       COALESCE((
      SELECT JSON_ARRAYAGG(filename)
        FROM order_images
       WHERE order_id = o.id
    ), JSON_ARRAY()) AS images,
    COALESCE((
  SELECT JSON_ARRAYAGG(
    JSON_OBJECT(
      'filename',     filename,
      'originalname', originalname
    )
  )
    FROM order_documents
   WHERE order_id = o.id
), JSON_ARRAY()) AS documents
      FROM orders o
      WHERE o.id = ?
    `, [orderId]);
    res.json(row);
  } catch (err) {
    console.error('Error fetching single order:', err);
    res.status(500).json({ error: err.message });
  }
});


app.get('/notifications', async (req, res) => {
  try {
    // 1) Read offset & limit from the query string (or use defaults)
    const offset = parseInt(req.query.offset, 10) || 0;
    const limit = parseInt(req.query.limit, 10) || 10;

    // 2) Query the notifications table, ordering by newest first
    const [rows] = await db.query(
      `
      SELECT
        id,
        message,
        url,
        created_at
      FROM notifications
      ORDER BY created_at DESC
      LIMIT ?
      OFFSET ?
      `,
      [limit, offset]
    );

    // 3) Return the resulting rows as JSON
    return res.json(rows);
  } catch (err) {
    console.error('GET /notifications error:', err);
    return res.status(500).json({ error: 'Could not fetch notifications' });
  }
});



// POST /orders with multiple images (max 10), HEIC→JPEG conversion, compression, and error handling
app.post(
  '/orders',
  // multer wrapper to catch MulterError
  (req, res, next) => {
    upload.fields([
      { name: 'images',    maxCount: 10 },
      { name: 'documents', maxCount:  5 }
    ])(req, res, err => {
      if (err instanceof multer.MulterError) {
        return res.status(400).json({ error: err.message });
      }
      next(err);
    });
  },
  async (req, res) => {
    const originals = (req.files['images'] || []).map(f => f.path);

    try {
      const { customerName, dateOrdered, jobId, address, phoneNumber, emailAddress, eta} = req.body;
      if (!customerName || !dateOrdered || !jobId || !eta) {
        return res.status(400).json({ error: 'Please provide all fields' });
      }

      const urgentFlag = Number(req.body.urgent) ? 1 : 0;
      const pickupFlag = Number(req.body.pickup) ? 1 : 0;
      
    

      // 1) Insert the order record
      const insertOrderSql = `
        INSERT INTO orders
          (customerName, dateOrdered, jobId, urgent, address, phoneNumber, emailAddress, pickup, eta)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `;
      const insertResult = await dbQuery(
        insertOrderSql,
        [customerName, dateOrdered, jobId, urgentFlag, address,phoneNumber,emailAddress, pickupFlag, eta]
      );
      const orderId = insertResult.insertId;

      // 2) Process each image file
      for (const file of req.files['images'] || []) {
        const ext     = path.extname(file.filename).toLowerCase();
        const base    = path.parse(file.filename).name;
        const outName = `compressed-${base}.jpg`;
        const inPath  = file.path;

        let jpegBuffer;

        if (ext === '.heic' || ext === '.heif') {
          // a) Read HEIC into a buffer
          const inputBuffer = await fs.promises.readFile(inPath);
          // b) Convert HEIC → JPEG
          const interimJpeg = await heicConvert({
            buffer: inputBuffer,
            format: 'JPEG',
            quality: 0.8
          });
          // c) Run through Sharp for rotate/resize/compression
          jpegBuffer = await sharp(interimJpeg,{ failOnError: false })
            .rotate()
            .resize({ width: 1600 })
            .jpeg({
              quality: 90,
              progressive: true,
              mozjpeg: true
            })
            .toBuffer();
        } else {
          // non-HEIC: direct Sharp pipeline
          jpegBuffer = await sharp(inPath,{ failOnError: false })
            .rotate()
            .resize({ width: 1600 })
            .jpeg({
              quality: 90,
              progressive: true,
              mozjpeg: true
            })
            .toBuffer();
        }

        // 3) Write the final JPEG and remove the original file
        const outPath = path.join(__dirname, 'uploads', outName);
        await fs.promises.writeFile(outPath, jpegBuffer);
        await fs.promises.unlink(inPath);

        // 4) Record it in the database
        await dbQuery(
          `INSERT INTO order_images (order_id, filename) VALUES (?, ?)`,
          [orderId, outName]
        );
      }

       // 4) Record each PDF in order_documents
       for (const doc of req.files['documents'] || []) {
        await dbQuery(
          'INSERT INTO order_documents (order_id, filename, originalname) VALUES (?, ?, ?)',
          [orderId, doc.filename, doc.originalname]
        );
      }

      
      // 5) Fetch and return the full order with its images
      const fetchSql = `
        SELECT
          o.id,
          o.customerName,
          o.dateOrdered,
          o.jobId,
          o.status,
          o.urgent,
          o.address,
          o.phoneNumber,
          o.emailAddress,
          o.pickup,
          o.eta,
          COALESCE((
      SELECT JSON_ARRAYAGG(filename)
        FROM order_images
       WHERE order_id = o.id
    ), JSON_ARRAY()) AS images,
    COALESCE((
  SELECT JSON_ARRAYAGG(
    JSON_OBJECT(
      'filename',     filename,
      'originalname', originalname
    )
  )
    FROM order_documents
   WHERE order_id = o.id
), JSON_ARRAY()) AS documents
        FROM orders o
        WHERE o.id = ?
      `;
      const [orderRow] = await dbQuery(fetchSql, [orderId]);

      res.json(orderRow);
      io.emit('ordersUpdated');
      io.emit('imagesUpdated', { orderId });

    } catch (err) {

      await Promise.all(
        originals.map(async p => {
          try { 
            await fs.promises.unlink(p);
          } catch (_) { /* ignore missing files */ }
        })
      );

      console.error('Image processing failed, cleaned up uploads:', err);
      res.status(500).json({ error: err.message });
    }
  }
);


// PATCH /orders/:id — update any of the main order fields in one go
app.patch('/orders/:id', ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  // only these columns are writable via this endpoint
  const allowed = [
    'customerName',
    'jobId',
    'dateOrdered',
    'eta',
    'address',
    'status',
    'phoneNumber',
    'emailAddress'
  ];

  // build SET clause dynamically
  const sets = [];
  const params = [];
  for (const field of allowed) {
    if (req.body[field] !== undefined) {
      sets.push(`\`${field}\` = ?`);
      params.push(req.body[field]);
    }
  }
  if (sets.length === 0) {
    return res.status(400).json({ error: 'No valid fields to update' });
  }

  try {
    // 1) perform the update
    await dbQuery(
      `UPDATE orders SET ${sets.join(', ')} WHERE id = ?`,
      [...params, orderId]
    );

    // 2) re-fetch the full order (with images & documents) exactly as in your other endpoints
    const fetchSql = `
      SELECT
        o.id,
        o.customerName,
        o.dateOrdered,
        o.jobId,
        o.status,
        o.urgent,
        o.address,
        o.phoneNumber,
        o.emailAddress,
        o.pickup,
        o.eta,
        COALESCE((
          SELECT JSON_ARRAYAGG(filename)
          FROM order_images
          WHERE order_id = o.id
        ), JSON_ARRAY()) AS images,
        COALESCE((
          SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
              'filename',     filename,
              'originalname', originalname
            )
          )
          FROM order_documents
          WHERE order_id = o.id
        ), JSON_ARRAY()) AS documents
      FROM orders o
      WHERE o.id = ?
    `;
    const [updatedOrder] = await dbQuery(fetchSql, [orderId]);

    // 3) send back the updated order, and notify clients
    res.json(updatedOrder);
    io.emit('ordersUpdated', {orderId});
  } catch (err) {
    console.error('Error in PATCH /orders/:id:', err);
    res.status(500).json({ error: err.message });
  }
});



//I need to get the Updates logic from here and add it to the orders patch so it shows what was changed.
/*
// Update status
app.patch('/orders/:id/status',ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  const { status } = req.body;
  const user     = req.username;  
  if (!status) return res.status(400).json({ error: 'Missing status' });

  try {
    const updateSql = `UPDATE orders SET status = ? WHERE id = ?`;
    await dbQuery(updateSql, [status, orderId]);

    const logText = `Status updated to "${status}"`;
    await dbQuery(
      `INSERT INTO order_updates (order_id, update_text, username)
       VALUES (?, ?, ?)`,
      [orderId, logText, user]
    );

    const fetchSql = `
      SELECT
        o.id,
        o.customerName,
        o.dateOrdered,
        o.jobId,
        o.status,
        o.urgent,
        o.address,
        o.phoneNumber,
        o.emailAddress,
        o.pickup,
        o.eta,
       COALESCE((
      SELECT JSON_ARRAYAGG(filename)
        FROM order_images
       WHERE order_id = o.id
    ), JSON_ARRAY()) AS images,
   COALESCE((
  SELECT JSON_ARRAYAGG(
    JSON_OBJECT(
      'filename',     filename,
      'originalname', originalname
    )
  )
    FROM order_documents
   WHERE order_id = o.id
), JSON_ARRAY()) AS documents
      FROM orders o
      WHERE o.id = ?

    `;
    const rows = await dbQuery(fetchSql, [orderId]);
    res.json(rows[0]);
    io.emit('ordersUpdated');
    io.emit('updatesUpdated', {orderId});
    io.emit('statusUpdated', rows[0]);
  } catch (err) {
    console.error('Error in PATCH /orders/:id/status:', err);
    res.status(500).json({ error: err.message });
  }
});
*/


// Delete order
app.delete('/orders/:id',ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  try {
    const imgRows = await dbQuery(
      'SELECT filename FROM order_images WHERE order_id = ?',
      [orderId]
    );
    for (const { filename } of imgRows) {
      try {
        await fs.promises.unlink(path.join(__dirname, 'uploads', filename));
      } catch (e) {
        console.warn(`Could not delete file ${filename}:`, e.message);
      }
    }
    const evidenceRows = await dbQuery(
      'SELECT filename FROM delivery_evidence_images WHERE order_id = ?',
      [orderId]
    );
    for (const { filename } of evidenceRows) {
      try {
        await fs.promises.unlink(path.join(__dirname, 'uploads', filename));
      } catch (e) {
        console.warn(`Could not delete evidence file ${filename}:`, e.message);
      }
    }
    const docRows = await dbQuery(
      'SELECT filename FROM order_documents WHERE order_id = ?',
      [orderId]
    );
    for (const { filename } of docRows) {
      try {
        await fs.promises.unlink(path.join(__dirname, 'uploads', filename));
      } catch (e) {
        console.warn(`Could not delete Document file ${filename}:`, e.message);
      }
    }

    const sigRows = await dbQuery(
      'SELECT filename FROM signature_images WHERE order_id = ?',
      [orderId]
    );
    for (const { filename } of sigRows) {
      try {
        await fs.promises.unlink(path.join(__dirname, 'uploads', filename));
      } catch (e) {
        console.warn(`Could not delete Document file ${filename}:`, e.message);
      }
    }


    await dbQuery('DELETE FROM delivery_evidence_images WHERE order_id = ?',[orderId]);
    await dbQuery('DELETE FROM order_images WHERE order_id = ?', [orderId]);
    await dbQuery('DELETE FROM signature_images WHERE order_id = ?', [orderId]);
    await dbQuery('DELETE FROM order_documents WHERE order_id = ?', [orderId]);
    await dbQuery('DELETE FROM orders WHERE id = ?', [orderId]);
    res.json({ success: true });
    io.emit('ordersUpdated');
    io.emit('orderDeleted',{orderId});
  } catch (err) {
    console.error('Error deleting order:', err);
    res.status(500).json({ error: err.message });
  }
});


// DELETE /orders/:id/images/:filename — remove one image
app.delete(
  '/orders/:id/images/:filename',
  ensureOrderExists,
  async (req, res) => {
    const orderId  = req.params.id;
    const filename = req.params.filename;

    try {
      // 1) Delete the file from disk
      await fs.promises.unlink(path.join(__dirname, 'uploads', filename));
    } catch (err) {
      console.warn(`Could not delete file ${filename}:`, err.message);
      return res.status(404).json({ error: 'Image not found' });
    }

    try {
      // 2) Remove its DB record
      await dbQuery(
        'DELETE FROM order_images WHERE order_id = ? AND filename = ?',
        [orderId, filename]
      );
      // 3) Notify all clients
      io.emit('ordersUpdated');
      io.emit('imagesUpdated', { orderId });
      return res.sendStatus(200);
    } catch (err) {
      console.error('Error deleting image record:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);


app.get(
  '/orders/:id/documents',
  ensureOrderExists,
  async (req, res) => {
    const orderId = Number(req.params.id);
    try {
      // fetch both stored and original names
      const rows = await dbQuery(
        `SELECT filename, originalname
           FROM order_documents
          WHERE order_id = ?`,
        [orderId]
      );
      // map to objects matching your Dart OrderDocument
      const docs = rows.map(r => ({
        filename:     r.filename,
        originalname: r.originalname
      }));
      return res.json(docs);
    } catch (err) {
      console.error('Error loading documents:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);

// POST /orders/:id/documents — upload extra PDF documents
app.post(
  '/orders/:id/documents',
  ensureOrderExists,
  // multer will parse up to 5 files under field "documents"
  (req, res, next) => upload.array('documents', 5)(req, res, next),
  async (req, res) => {
    const orderId = req.params.id;
    const files = req.files || [];

    try {
      // 1) Record each uploaded PDF in the DB
      for (const file of files) {
        await dbQuery(
          'INSERT INTO order_documents (order_id, filename, originalname) VALUES (?, ?, ?)',
          [orderId, file.filename, file.originalname]
        );
      }

      // 2) Notify connected clients
      io.emit('documentsUpdated', {orderId});
      io.emit('ordersUpdated');

      // 3) Return success
      return res.sendStatus(200);
    } catch (err) {
      console.error('Error uploading documents:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);

app.delete(
  '/orders/:id/documents/:filename',
  ensureOrderExists,
  async (req, res) => {
    const orderId  = req.params.id;
    const filename = req.params.filename;

    // 1) Remove the file from disk
    try {
      await fs.promises.unlink(path.join(__dirname, 'uploads', filename));
    } catch (err) {
      console.warn(`Could not delete document file ${filename}:`, err.message);
      return res.status(404).json({ error: 'Document not found' });
    }

    // 2) Remove its database record
    try {
      await dbQuery(
        'DELETE FROM order_documents WHERE order_id = ? AND filename = ?',
        [orderId, filename]
      );
      // 3) Notify clients
      io.emit('ordersUpdated');
      io.emit('documentsUpdated', {orderId});
      return res.sendStatus(200);
    } catch (err) {
      console.error('Error deleting document record:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);

// DELETE a single delivery-evidence image
app.delete(
  '/orders/:id/delivery-evidence/:filename',
  ensureOrderExists,
  async (req, res) => {
    const orderId  = req.params.id;
    const filename = req.params.filename;

    // 1) Remove the file from disk
    try {
      await fs.promises.unlink(path.join(__dirname, 'uploads', filename));
    } catch (err) {
      console.warn(`Could not delete evidence file ${filename}:`, err.message);
      return res.status(404).json({ error: 'Evidence file not found' });
    }

    // 2) Remove the DB record
    try {
      await dbQuery(
        'DELETE FROM delivery_evidence_images WHERE order_id = ? AND filename = ?',
        [orderId, filename]
      );
      // 3) Notify clients that evidence changed
      io.emit('evidenceUpdated', { orderId });
      return res.sendStatus(200);
    } catch (err) {
      console.error('Error deleting evidence record:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);


// Fetch order updates
app.get('/orders/:id/updates',ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  try {
    const rows = await dbQuery(
      `SELECT
         id,
         update_text   AS text,
         username,
         created_at
       FROM order_updates
       WHERE order_id = ?
       ORDER BY created_at DESC`,
      [orderId]
    );
    res.json(rows);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

// Add order update
app.post('/orders/:id/updates',ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  const { text } = req.body;
  const user = req.username;              // from authenticateToken

  if (!text) return res.status(400).json({ error: 'Missing update text' });

  try {
    // Insert with username
    const result = await dbQuery(
      `INSERT INTO order_updates (order_id, update_text, username)
       VALUES (?, ?, ?)`,
      [orderId, text, user]
    );

    // Return the new record (including username)
    const [newUpdate] = await dbQuery(
      `SELECT
         id,
         update_text AS text,
         username,
         created_at
       FROM order_updates
       WHERE id = ?`,
      [result.insertId]
    );
    res.status(201).json(newUpdate);
    io.emit('updatesUpdated', {orderId});
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

// PATCH /orders/:orderId/updates/:updateId
app.patch('/orders/:id/updates/:updateId',ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  const updateId = req.params.updateId;
  const { text } = req.body;
  const user       = req.username;

  if (!text) return res.status(400).json({ error: 'Missing update text' });

  try {  //  fetch the existing update’s owner
    const rows = await dbQuery(
      `SELECT username FROM order_updates WHERE id = ? AND order_id = ?`,
      [updateId, orderId]
    );
    if (rows.length === 0) return res.status(404).json({ error: 'Update not found' });
    if (rows[0].username !== user) 
      return res.status(403).json({ error: 'You can only edit your own updates' });
  
    //  now safe to update
    await dbQuery(
      `UPDATE order_updates SET update_text = ? WHERE id = ? AND order_id = ?`,
      [text, updateId, orderId]
    );
    const [updated] = await dbQuery(
      `SELECT id, update_text AS text, username, created_at
         FROM order_updates
        WHERE id = ?`,
      [updateId]
    );
    res.json(updated);
    io.emit('updatesUpdated', {orderId});
  }
    catch (err) {
      console.error(err);
      res.status(500).json({ error: err.message });
    }
});

// DELETE /orders/:orderId/updates/:updateId
app.delete('/orders/:id/updates/:updateId',ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  const updateId = req.params.updateId;
  const user = req.username;
  
  //  ownership check
  const rows = await dbQuery(
    `SELECT username FROM order_updates WHERE id = ? AND order_id = ?`,
    [updateId, orderId]
  );
  if (rows.length === 0) return res.status(404).json({ error: 'Update not found' });

  

  if (rows[0].username !== user)
    return res.status(403).json({ error: 'You can only delete your own updates' });

  //  safe to delete
  await dbQuery(
    `DELETE FROM order_updates WHERE id = ? AND order_id = ?`,
    [updateId, orderId]
  );
  res.json({ success: true });
  io.emit('updatesUpdated', {orderId});
});



// ----- DELIVERY EVIDENCE -----
// GET existing evidence URLs
app.get('/orders/:id/delivery-evidence', async (req, res) => {
   const orderId = req.params.id;
  try {
     const rows = await dbQuery(
        'SELECT filename FROM delivery_evidence_images WHERE order_id = ? ORDER BY id',
        [orderId]
      );
     
      const urls = rows.map(r => `/uploads/${r.filename}`);
      res.json(urls);
    
   } catch (err) {
      console.error(err);
      res.status(500).json({ error: err.message });
    }
  });


// POST /orders/:id/images — upload extra images to an existing order
app.post(
  '/orders/:id/images',
  ensureOrderExists,
  // multer will parse up to 10 files under field "images"
  (req, res, next) => upload.array('images', 10)(req, res, next),
  async (req, res) => {
    const orderId = req.params.id;
    const originals = (req.files || []).map(f => f.path);

    try {
      for (const file of req.files || []) {
        const ext     = path.extname(file.filename).toLowerCase();
        const base    = path.parse(file.filename).name;
        const outName = `compressed-${base}.jpg`;
        const inPath  = file.path;

       

        // HEIC → JPEG + Sharp pipeline
        let jpegBuffer;
        if (ext === '.heic' || ext === '.heif') {
          const inputBuffer = await fs.promises.readFile(inPath);
          const interimJpeg = await heicConvert({
            buffer: inputBuffer,
            format: 'JPEG',
            quality: 0.8,
          });
          jpegBuffer = await sharp(interimJpeg,{ failOnError: false })
            .rotate()
            .resize({ width: 1600 })
            .jpeg({
              quality: 90,
              progressive: true,
              mozjpeg: true
            })
            .toBuffer();
        } else {
          jpegBuffer = await sharp(inPath,{ failOnError: false })
            .rotate()
            .resize({ width: 1600 })
            .jpeg({
              quality: 90,
              progressive: true,
              mozjpeg: true
            })
            .toBuffer();
        }

        // write compressed JPG & remove original
        await fs.promises.writeFile(
          path.join(__dirname, 'uploads', outName),
          jpegBuffer
        );
        await fs.promises.unlink(inPath);

        // record in database
        await dbQuery(
          'INSERT INTO order_images (order_id, filename) VALUES (?, ?)',
          [orderId, outName]
        );
      }

      // notify clients to refresh images
      io.emit('imagesUpdated', {orderId});
      io.emit('ordersUpdated');
      return res.sendStatus(200);

    } catch (err) {

      await Promise.all(
        originals.map(async p => {
          try { 
            await fs.promises.unlink(p);
          } catch (_) { /* ignore missing files */ }
        })
      );

      console.error('Image processing failed, cleaned up uploads:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);


app.get('/orders/:id/signature', ensureOrderExists, async (req, res) => {
  const orderId = req.params.id;
  try {
    const rows = await dbQuery(
      `SELECT signature_name, created_at, filename
         FROM signature_images
        WHERE order_id = ?
        ORDER BY id DESC`,        // grab all, newest first
      [orderId]
    );
    if (rows.length === 0) {
       // No signature yet → return an “empty” signature object
       return res.json({
        name: '',
        date: new Date().toISOString(),  // or '' if you prefer
        images: []
      });
    }

    // the first row has the signer & timestamp; collect all image URLs
    const { signature_name, created_at } = rows[0];
    const images = rows.map(r => `/uploads/${r.filename}`);

    res.json({
      name: signature_name,
      date: created_at,
      images
    });
  } catch (err) {
    console.error('Failed to fetch signature:', err);
    res.status(500).json({ error: 'Server error' });
  }
});

// POST /orders/:id/signature
app.post(
  '/orders/:id/signature',
  ensureOrderExists,
  (req, res, next) => upload.single('signature')(req, res, next),
  async (req, res) => {
    const orderId = req.params.id;
    const original = req.file?.path;
    const signer   = req.body.name;

    // validate both file and name
    if (!original || !signer) {
      return res.status(400).json({ error: 'Missing file or name' });
    }

    // build final filename & path
    const base      = path.parse(req.file.filename).name;
    const finalName = `signature-${base}.jpg`;
    const finalPath = path.join(__dirname, 'uploads', finalName);

    try {
      // 1) Delete old signatures (both DB rows and files)
      const old = await dbQuery(
        'SELECT filename FROM signature_images WHERE order_id = ?',
        [orderId]
      );
      for (const { filename } of old) {
        await fs.promises.unlink(path.join(__dirname, 'uploads', filename))
          .catch(() => {}); // ignore missing
      }
      await dbQuery(
        'DELETE FROM signature_images WHERE order_id = ?',
        [orderId]
      );

      // 2) Convert upload to JPEG via Sharp
      await sharp(original, { failOnError: false })
        .flatten({ background: '#ffffff' })
        .rotate()
        .resize({ width: 1600 })
        .jpeg({ quality: 95, progressive: true, mozjpeg: true })
        .toFile(finalPath);

      // remove the original upload
      await fs.promises.unlink(original);

      // 3) Save new signature record (name + filename, created_at auto-fills)
      await dbQuery(
        `INSERT INTO signature_images
           (order_id, filename, signature_name)
         VALUES (?, ?, ?)`,
        [orderId, finalName, signer]
      );

      // 4) notify clients
      io.emit('signatureUpdated', { orderId });
      return res.sendStatus(200);
    } catch (err) {
      console.error('Error saving signature:', err);
      // clean up any half-written files
      await fs.promises.unlink(original).catch(() => {});
      return res.status(500).json({ error: 'Failed to process signature' });
    }
  }
);




  
// POST new evidence (up to 10 files) with HEIC→JPEG + Sharp compression
app.post(
  '/orders/:id/delivery-evidence',
  ensureOrderExists,
  (req, res, next) => upload.array('evidence', 10)(req, res, next),
  async (req, res) => {
    const orderId = req.params.id;
    const originals = (req.files || []).map(f => f.path);
    try {
      for (const file of req.files) {
        const ext     = path.extname(file.filename).toLowerCase();
        const base    = path.parse(file.filename).name;
        const outName = `evidence-${base}.jpg`;
        const inPath  = file.path;
        let pipeline;

        if (ext === '.heic' || ext === '.heif') {
          // 1) Read HEIC into Buffer
          const inputBuffer = await fs.promises.readFile(inPath);
          // 2) Convert HEIC → JPEG
          const interimJpeg = await heicConvert({
            buffer: inputBuffer,
            format: 'JPEG',
            quality: 0.8
          });
          // 3) Feed into Sharp
          pipeline = sharp(interimJpeg,{ failOnError: false });
        } else {
          // non-HEIC: use file path
          pipeline = sharp(inPath, { failOnError: false }).flatten({ background: '#ffffff' });
        }

        // 4) Rotate, resize, JPEG compress, and write out
        await pipeline
          .rotate()
          .resize({ width: 1600 })
          .jpeg({
            quality: 90,
            progressive: true,
            mozjpeg: true
          })
          .toFile(path.join(__dirname, 'uploads', outName));

        // 5) Remove original upload
        await fs.promises.unlink(inPath);

        // 6) Record in database
        await dbQuery(
          'INSERT INTO delivery_evidence_images (order_id, filename) VALUES (?, ?)',
          [orderId, outName]
        );
      }

      res.sendStatus(200);
      io.emit('evidenceUpdated', { orderId });
    } catch (err) {
      await Promise.all(
        originals.map(async p => {
          try { 
            await fs.promises.unlink(p);
          } catch (_) { /* ignore missing files */ }
        })
      );
      console.error('Image processing failed, cleaned up uploads:', err);
      res.status(500).json({ error: err.message });
    }
  }
);


// after you’ve mounted all your API routes and your static folder…
app.use(express.static(path.join(__dirname, 'build', 'web')));

// catch-all — this uses a string, not a RegExp, so path-to-regexp handles it cleanly
 app.get( '/{*splat}', (req, res) => {
  res.sendFile(path.join(__dirname, 'build', 'web', 'index.html'));
 });

server.listen(PORT, '0.0.0.0', () =>
  console.log(`Listening on 0.0.0.0:${PORT}`)
);