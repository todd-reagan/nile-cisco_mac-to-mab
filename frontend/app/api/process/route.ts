import { NextRequest, NextResponse } from 'next/server';

// In a real implementation, this would be the AWS API Gateway URL
const API_ENDPOINT = process.env.LAMBDA_API_ENDPOINT || 'https://your-api-gateway-url.execute-api.region.amazonaws.com/prod/process';

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    
    // In a production environment, this would call the actual Lambda function via API Gateway
    // For development/demo purposes, we're implementing the processing logic here
    
    const { fileContent, vlanMappings } = body;
    
    if (!fileContent) {
      return NextResponse.json(
        { error: 'No file content provided' },
        { status: 400 }
      );
    }
    
    // Decode base64 content
    let decodedContent;
    try {
      decodedContent = atob(fileContent);
    } catch (error) {
      console.error('Error decoding base64 content:', error);
      return NextResponse.json(
        { error: 'Invalid file content encoding' },
        { status: 400 }
      );
    }
    
    // Parse the file content
    try {
      const { clients, uniqueVlans, detectedMappings } = parseFileContent(decodedContent);
      
      if (clients.length === 0) {
        return NextResponse.json(
          { error: 'No valid MAC address entries found in the file' },
          { status: 400 }
        );
      }
      
      // Use provided mappings or detected mappings
      const finalMappings = Object.keys(vlanMappings).length > 0 ? vlanMappings : detectedMappings;
      
      // Generate CSV
      const csvContent = generateCsv(clients, finalMappings);
      
      // Return the CSV content and detected mappings
      return NextResponse.json({
        csvContent: btoa(csvContent),
        detectedMappings
      });
    } catch (error) {
      console.error('Error parsing file content:', error);
      return NextResponse.json(
        { error: 'Failed to parse file content' },
        { status: 400 }
      );
    }
  } catch (error) {
    console.error('Error processing file:', error);
    return NextResponse.json(
      { error: 'Failed to process file' },
      { status: 500 }
    );
  }
}

// Parse the file content
function parseFileContent(content: string) {
  const lines = content.trim().split('\n');
  const clients: any[] = [];
  const uniqueVlans = new Set<number>();
  const detectedMappings: Record<string, string> = {};
  
  lines.forEach(line => {
    const trimmedLine = line.trim();
    if (!trimmedLine) return;
    
    // Check if line matches the VLAN mapping format: number = 'segment name'
    const mappingMatch = trimmedLine.match(/^(\d+)\s*=\s*['"]?(.*?)['"]?$/);
    if (mappingMatch) {
      const vlanId = parseInt(mappingMatch[1], 10);
      const segmentName = mappingMatch[2];
      detectedMappings[vlanId.toString()] = segmentName;
      return;
    }
    
    // Split by whitespace
    const parts = trimmedLine.split(/\s+/);
    if (parts.length < 4) return;
    
    try {
      const vlan = parseInt(parts[0], 10);
      const mac = parts[1];
      const port = parts[3];
      
      if (!isNaN(vlan) && mac && port) {
        uniqueVlans.add(vlan);
        clients.push({
          vlan,
          mac,
          port
        });
      }
    } catch (error) {
      // Skip lines that don't match the expected format
    }
  });
  
  return {
    clients,
    uniqueVlans: Array.from(uniqueVlans).sort((a, b) => a - b),
    detectedMappings
  };
}

// Format MAC address
function formatMacAddress(mac: string): string {
  // Remove any separators and convert to lowercase
  mac = mac.toLowerCase().replace(/[.:-]/g, '');
  
  // Handle Cisco format (001e.0b41.7afd)
  if (mac.length === 12) {
    return mac.match(/.{1,2}/g)?.join(':') || mac;
  }
  
  // Return original if we can't parse it
  return mac;
}

// Generate CSV
function generateCsv(clients: any[], vlanMappings: Record<string, string>): string {
  const headers = [
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
  ];
  
  const rows = [
    headers.join(','),
    ...clients.map(client => {
      const vlan = client.vlan;
      const segment = vlanMappings[vlan] || '';
      
      return [
        formatMacAddress(client.mac),
        segment,
        '',  // Lock to Port (removed as requested)
        '',  // Site
        '',  // Building
        '',  // Floor
        'Allow',
        '',  // Description (removed as requested)
        'No',  // Static IP
        '',    // IP Address
        'No'   // Passive IP
      ].join(',');
    })
  ];
  
  return rows.join('\n');
}
