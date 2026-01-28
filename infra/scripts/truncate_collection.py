#!/usr/bin/env python3
"""
Script para truncar (limpar todos os pontos) de uma collection do Qdrant.
Uso: python truncate_collection.py <collection_name>
"""
import sys
from pathlib import Path

# Adicionar /app ao path
_APP_ROOT = Path('/app')
if str(_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(_APP_ROOT))

from qdrant_client import QdrantClient
from qdrant_client.http import models as qm
from app.config import settings

def truncate_collection(collection_name: str) -> int:
    """Trunca uma collection do Qdrant (deleta todos os pontos)."""
    try:
        qdrant = QdrantClient(url=settings.qdrant_url, timeout=30.0)
        
        # Verificar se collection existe
        try:
            collection_info = qdrant.get_collection(collection_name)
            points_count = collection_info.points_count
            print(f'[INFO] Collection "{collection_name}" existe com {points_count} pontos')
        except Exception as e:
            if '404' in str(e) or 'not found' in str(e).lower():
                print(f'[AVISO] Collection "{collection_name}" não existe. Será criada durante a ingestão.')
                return 0
            else:
                raise
        
        # Truncar: deletar todos os pontos usando scroll para pegar todos os IDs
        print(f'[INFO] Coletando IDs de todos os pontos...')
        all_ids = []
        offset = None
        while True:
            result = qdrant.scroll(
                collection_name=collection_name,
                limit=1000,
                offset=offset,
                with_payload=False,
                with_vectors=False
            )
            points, next_offset = result
            if not points:
                break
            all_ids.extend([p.id for p in points])
            if next_offset is None:
                break
            offset = next_offset
        
        if all_ids:
            print(f'[INFO] Deletando {len(all_ids)} pontos...')
            # Deletar em lotes de 1000 para evitar timeout
            batch_size = 1000
            for i in range(0, len(all_ids), batch_size):
                batch = all_ids[i:i+batch_size]
                qdrant.delete(
                    collection_name=collection_name,
                    points_selector=qm.PointIdsList(
                        points=batch
                    )
                )
                print(f'  Deletados {min(i+batch_size, len(all_ids))}/{len(all_ids)} pontos...')
            
            print(f'[OK] Collection "{collection_name}" truncada com sucesso ({len(all_ids)} pontos removidos)')
        else:
            print(f'[INFO] Collection "{collection_name}" já está vazia')
        
        return 0
    
    except Exception as e:
        error_msg = str(e)
        print(f'[ERRO] Falha ao truncar collection: {error_msg}')
        import traceback
        traceback.print_exc()
        return 1

if __name__ == '__main__':
    collection_name = sys.argv[1] if len(sys.argv) > 1 else 'docs_chunks'
    sys.exit(truncate_collection(collection_name))
