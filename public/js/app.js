// DompetHarian - Client Side Application Code

document.addEventListener('DOMContentLoaded', () => {
  // 1. Initialize Navigation Tabs Active State
  const path = window.location.pathname;
  const navItems = document.querySelectorAll('.nav-item, .mobile-nav-item');
  
  navItems.forEach(item => {
    const link = item.querySelector('a') || item;
    const href = link.getAttribute('href');
    
    // Check if path matches href
    if (href === path || (path === '/' && href === '/') || (path.startsWith(href) && href !== '/')) {
      item.classList.add('active');
    } else {
      item.classList.remove('active');
    }
  });

  // Initialize Lucide icons if present
  if (typeof lucide !== 'undefined') {
    lucide.createIcons();
  }

  // 2. Modal/Drawer Management
  const modalOverlay = document.getElementById('add-expense-modal');
  const addButtons = document.querySelectorAll('.trigger-add-expense');
  const closeModalButton = document.querySelector('.modal-close');

  const openModal = () => {
    if (modalOverlay) {
      modalOverlay.classList.add('open');
      document.body.style.overflow = 'hidden'; // Prevent background scrolling
      // Set default date to today
      const dateInput = document.getElementById('expense-date');
      if (dateInput && !dateInput.value) {
        const today = new Date().toISOString().split('T')[0];
        dateInput.value = today;
      }
    }
  };

  const closeModal = () => {
    if (modalOverlay) {
      modalOverlay.classList.remove('open');
      document.body.style.overflow = '';
      // Reset form on close
      const form = modalOverlay.querySelector('form');
      if (form) form.reset();
      const amountPreview = document.getElementById('amount-preview');
      if (amountPreview) amountPreview.textContent = '';
    }
  };

  addButtons.forEach(btn => btn.addEventListener('click', (e) => {
    e.preventDefault();
    openModal();
  }));

  if (closeModalButton) {
    closeModalButton.addEventListener('click', closeModal);
  }

  if (modalOverlay) {
    modalOverlay.addEventListener('click', (e) => {
      if (e.target === modalOverlay) closeModal();
    });
  }

  // 3. IDR Amount Formatter Preview
  const amountInput = document.getElementById('expense-amount');
  const amountPreview = document.getElementById('amount-preview');

  if (amountInput && amountPreview) {
    amountInput.addEventListener('input', (e) => {
      const val = parseFloat(e.target.value);
      if (!isNaN(val) && val > 0) {
        // Format Indonesian Rupiah
        const formatted = new Intl.NumberFormat('id-ID', {
          style: 'currency',
          currency: 'IDR',
          minimumFractionDigits: 0
        }).format(val);
        amountPreview.textContent = formatted;
        amountPreview.style.color = 'var(--accent-success)';
      } else {
        amountPreview.textContent = '';
      }
    });
  }

  // 4. Notification helper
  const showNotification = (message, type = 'success') => {
    // Check if container exists, else create it
    let notif = document.getElementById('app-notification');
    if (!notif) {
      notif = document.createElement('div');
      notif.id = 'app-notification';
      notif.className = 'notification';
      document.body.appendChild(notif);
    }
    
    // Set type icon
    const icon = type === 'success' ? 'check-circle' : 'alert-circle';
    notif.className = `notification ${type}`;
    notif.innerHTML = `
      <i class="lucide-${icon}" data-lucide="${icon}"></i>
      <span>${message}</span>
    `;
    
    if (typeof lucide !== 'undefined') {
      lucide.createIcons();
    }
    
    // Show notification
    setTimeout(() => {
      notif.classList.add('show');
    }, 50);

    // Hide after 3 seconds
    setTimeout(() => {
      notif.classList.remove('show');
    }, 3000);
  };

  // 5. Submit Form via AJAX
  const addForm = document.getElementById('expense-form');
  if (addForm) {
    addForm.addEventListener('submit', (e) => {
      e.preventDefault();
      
      const formData = new FormData(addForm);
      const searchParams = new URLSearchParams();
      
      for (const pair of formData) {
        searchParams.append(pair[0], pair[1]);
      }
      
      // Submit via fetch
      fetch('/expenses', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: searchParams
      })
      .then(response => response.json().then(data => ({ status: response.status, body: data })))
      .then(res => {
        if (res.status === 200 && res.body.success) {
          showNotification(res.body.message, 'success');
          closeModal();
          // Reload page to reflect changes
          setTimeout(() => {
            window.location.reload();
          }, 800);
        } else {
          showNotification(res.body.error || 'Terjadi kesalahan.', 'error');
        }
      })
      .catch(err => {
        console.error('Error adding expense:', err);
        showNotification('Gagal menghubungi server.', 'error');
      });
    });
  }

  // 6. Delete Transaction via AJAX
  const deleteForms = document.querySelectorAll('.delete-expense-form');
  deleteForms.forEach(form => {
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      
      if (!confirm('Apakah Anda yakin ingin menghapus catatan pengeluaran ini?')) {
        return;
      }
      
      const action = form.getAttribute('action');
      const itemRow = form.closest('.expense-item');
      
      fetch(action, {
        method: 'POST',
        headers: {
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: ''
      })
      .then(response => response.json().then(data => ({ status: response.status, body: data })))
      .then(res => {
        if (res.status === 200 && res.body.success) {
          showNotification(res.body.message, 'success');
          
          // Animate list removal
          if (itemRow) {
            itemRow.style.transition = 'all 0.5s ease';
            itemRow.style.opacity = '0';
            itemRow.style.transform = 'translateX(100px)';
            
            setTimeout(() => {
              itemRow.remove();
              // Reload page to update metrics
              window.location.reload();
            }, 500);
          } else {
            window.location.reload();
          }
        } else {
          showNotification(res.body.error || 'Gagal menghapus catatan.', 'error');
        }
      })
      .catch(err => {
        console.error('Error deleting expense:', err);
        showNotification('Gagal menghubungi server.', 'error');
      });
    });
  });
});
