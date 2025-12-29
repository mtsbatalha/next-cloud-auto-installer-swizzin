# Scripts Extras do Nextcloud Auto-Installer

Este diretório contém scripts opcionais para funcionalidades avançadas.

## 📞 Nextcloud Talk (`install-talk.sh`)

Instala o **Nextcloud Talk** completo com:
- **Talk app (Spreed)**: App de vídeo chamadas e chat
- **Coturn**: Servidor TURN/STUN para NAT traversal
- **HPB**: High-Performance Backend para escalabilidade

### Requisitos
- Mínimo 2GB RAM adicional
- Portas abertas: 3478, 5349, 8080, 49152-65535
- Certificado SSL válido

### Uso
```bash
sudo chmod +x extras/install-talk.sh
sudo ./extras/install-talk.sh
```

### Depois da Instalação
- Talk estará disponível no menu de apps do Nextcloud
- Use chamadas de vídeo 1-a-1 ou em grupo
- Chat persistente e compartilhamento de tela

---

## ⚡ Nginx PageSpeed (`install-pagespeed.sh`)

Substitui o Nginx padrão por versão compilada com **PageSpeed Module**.

### O que faz
- Otimização automática de imagens
- Minificação de CSS/JS
- Lazy loading de imagens
- Combinação de arquivos CSS/JS
- Remoção de comentários e whitespace

### Requisitos
- 10-30 minutos para compilar
- 2GB+ espaço em disco durante compilação
- Backup automático do Nginx atual

### Uso
```bash
sudo chmod +x extras/install-pagespeed.sh
sudo ./extras/install-pagespeed.sh
```

### Depois da Instalação
- PageSpeed estará ativo automaticamente
- Cache em `/var/ngx_pagespeed_cache`
- Logs em `/var/log/pagespeed`

### Verificar se está funcionando
```bash
curl -I https://seu-dominio | grep X-Page-Speed
```

---

## ⚠️ Avisos Importantes

1. **Execute APÓS a instalação principal**
   ```bash
   # Primeiro
   sudo ./install.sh
   
   # Depois (opcional)
   sudo ./extras/install-talk.sh
   sudo ./extras/install-pagespeed.sh
   ```

2. **Talk requer recursos significativos**
   - RAM adicional para HPB e Coturn
   - Largura de banda para relay de mídia
   - Certificados SSL válidos

3. **PageSpeed recompila o Nginx**
   - Processo longo (10-30min)
   - Faz backup automático antes
   - Não pode ser facilmente desfeito

---

## 🆘 Troubleshooting

### Talk não funciona
```bash
# Verificar status dos serviços
systemctl status coturn
systemctl status talk-hpb

# Ver logs
journalctl -u coturn -f
journalctl -u talk-hpb -f

# Testar portas
sudo netstat -tulpn | grep -E '3478|5349|8080'
```

### PageSpeed com problemas
```bash
# Verificar se está ativo
nginx -V 2>&1 | grep pagespeed

# Ver configuração
cat /etc/nginx/conf.d/pagespeed.conf

# Restaurar backup
systemctl stop nginx
cp -r /root/nginx-backup-TIMESTAMP/nginx/* /etc/nginx/
systemctl start nginx
```

---

## 📚 Links Úteis

- [Nextcloud Talk Documentation](https://nextcloud-talk.readthedocs.io/)
- [Coturn Documentation](https://github.com/coturn/coturn/wiki)
- [PageSpeed Documentation](https://www.modpagespeed.com/)
