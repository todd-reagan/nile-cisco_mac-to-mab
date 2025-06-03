import json
import csv
import io
import base64
import re

def parse_cisco_mab_file(content):
    """
    Parse the Cisco MAC address binding file content.
    Format example:
       1    001e.0b41.7afd    DYNAMIC     Gi1/0/15
    
    Also parses optional header section with VLAN to segment mappings:
    1 = 'Wired Production'
    5 = 'Wired Production'
    """
    lines = content.strip().split('\n')
    clients = []
    unique_vlans = set()
    vlan_mappings = {}
    
    # First pass: check for optional header section with VLAN mappings
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
            
        # Check if line matches the VLAN mapping format: number = 'segment name'
        mapping_match = re.match(r'^(\d+)\s*=\s*[\'"]?(.*?)[\'"]?$', line)
        if mapping_match:
            vlan_id = int(mapping_match.group(1))
            segment_name = mapping_match.group(2)
            vlan_mappings[str(vlan_id)] = segment_name
        else:
            # If we find a line that doesn't match the mapping format, assume we're in the MAC address section
            # Split by whitespace
            parts = re.split(r'\s+', line)
            if len(parts) >= 4:
                try:
                    vlan = int(parts[0])
                    mac = parts[1]
                    port = parts[3]
                    
                    unique_vlans.add(vlan)
                    clients.append({
                        'vlan': vlan,
                        'mac': mac,
                        'port': port
                    })
                except (ValueError, IndexError):
                    # Skip lines that don't match the expected format
                    continue
    
    return clients, list(unique_vlans), vlan_mappings

def format_mac_address(mac):
    """
    Ensure MAC address is in the standard format (XX:XX:XX:XX:XX:XX)
    """
    # Remove any separators and convert to lowercase
    mac = re.sub(r'[.:-]', '', mac.lower())
    
    # Handle Cisco format (001e.0b41.7afd)
    if len(mac) == 12:
        return ':'.join([mac[i:i+2] for i in range(0, 12, 2)])
    
    # Return original if we can't parse it
    return mac

def generate_csv(clients, vlan_to_segment):
    """
    Generate CSV content for Nile import
    """
    output = io.StringIO()
    writer = csv.writer(output)
    
    # Write headers
    writer.writerow([
        'MAC Address (Required)',
        'Segment (Required for allow state)',
        'Lock to Port (Optional)',
        'Site (Optional)',
        'Building (Optional)',
        'Floor (Optional)',
        'Allow or Deny (Required)',
        'Description (Optional)',
        'Static IP (Optional)',
        'IP Address (Optional)',
        'Passive IP (Optional)'
    ])
    
    # Write client data
    for client in clients:
        vlan = client['vlan']
        segment = vlan_to_segment.get(str(vlan), '')
        
        writer.writerow([
            format_mac_address(client['mac']),
            segment,
            '',  # Lock to Port
            '',  # Site
            '',  # Building
            '',  # Floor
            'Allow',
            '',  # Description
            'No',  # Static IP
            '',    # IP Address
            'No'   # Passive IP
        ])
    
    return output.getvalue()

def lambda_handler(event, context):
    """
    AWS Lambda handler function
    """
    # Handle OPTIONS request (CORS preflight)
    if event.get('httpMethod') == 'OPTIONS' or event.get('requestContext', {}).get('http', {}).get('method') == 'OPTIONS':
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': '*',
                'Access-Control-Allow-Headers': '*',
                'Access-Control-Expose-Headers': '*',
                'Access-Control-Max-Age': '3600'
            },
            'body': json.dumps({})
        }
    
    try:
        # Parse the request body
        body = json.loads(event.get('body', '{}'))
        
        # Get the file content (base64 encoded)
        file_content = body.get('fileContent', '')
        if not file_content:
            return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': '*',
                'Access-Control-Allow-Headers': '*',
                'Access-Control-Expose-Headers': '*',
                'Access-Control-Max-Age': '3600'
            },
                'body': json.dumps({'error': 'No file content provided'})
            }
        
        # Decode the base64 content
        try:
            decoded_content = base64.b64decode(file_content).decode('utf-8')
        except Exception as e:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*',
                    'Access-Control-Allow-Methods': 'POST, OPTIONS',
                    'Access-Control-Allow-Headers': 'Content-Type'
                },
                'body': json.dumps({'error': f'Invalid base64 encoding: {str(e)}'})
            }
        
        # Parse the file
        clients, unique_vlans, detected_mappings = parse_cisco_mab_file(decoded_content)
        
        # Get VLAN to segment mappings from request or use detected mappings
        vlan_mappings = body.get('vlanMappings', {})
        
        # If no mappings were provided but we detected some, use those
        if not vlan_mappings and detected_mappings:
            vlan_mappings = detected_mappings
        
        # Check if we have any clients
        if not clients:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*',
                    'Access-Control-Allow-Methods': 'POST, OPTIONS',
                    'Access-Control-Allow-Headers': 'Content-Type'
                },
                'body': json.dumps({'error': 'No valid MAC address entries found in the file'})
            }
        
        # Generate CSV
        csv_content = generate_csv(clients, vlan_mappings)
        
        # Return the CSV content
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': '*',
                'Access-Control-Allow-Headers': '*',
                'Access-Control-Expose-Headers': '*',
                'Access-Control-Max-Age': '3600'
            },
            'body': json.dumps({
                'csvContent': base64.b64encode(csv_content.encode('utf-8')).decode('utf-8'),
                'detectedMappings': detected_mappings
            })
        }
    
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': '*',
                'Access-Control-Allow-Headers': '*',
                'Access-Control-Expose-Headers': '*',
                'Access-Control-Max-Age': '3600'
            },
            'body': json.dumps({'error': str(e)})
        }
